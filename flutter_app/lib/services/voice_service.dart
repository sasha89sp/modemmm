import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'debug_profiler_service.dart';
import 'win32_serial.dart';
import 'winmm_audio.dart';

class VoicePhraseItem {
  final String name;
  final String path;
  final int sizeBytes;

  const VoicePhraseItem({
    required this.name,
    required this.path,
    required this.sizeBytes,
  });
}

/// Управление голосовым аудиоканалом Huawei E173 по отдельному звуковому COM-порту (winmm.dll)
/// и библиотекой голосовых фраз UserData/Sounds.
class VoiceService {
  final WinmmAudio audio;
  final Win32SerialPort _voicePort = Win32SerialPort();
  final void Function()? onChanged;
  final DebugProfilerService? profiler;

  Timer? _rxTimer;
  bool _bridgeActive = false;
  bool _micMuted = false;
  bool _speakerMuted = false;
  bool _streamingPhrase = false;
  int _rxBytes = 0;
  int _txBytes = 0;
  String? lastVoiceError;
  DateTime _lastCounterNotify = DateTime.fromMillisecondsSinceEpoch(0);

  VoiceService(this.audio, {this.onChanged, this.profiler});

  void _notifyCountersThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastCounterNotify).inMilliseconds >= 400) {
      _lastCounterNotify = now;
      onChanged?.call();
    }
  }

  bool get isBridgeActive => _bridgeActive;
  bool get isMicMuted => _micMuted;
  bool get isSpeakerMuted => _speakerMuted;
  bool get isRecordingPhrase => audio.isRecording && !_bridgeActive;
  bool get isStreamingPhrase => _streamingPhrase;
  int get rxBytes => _rxBytes;
  int get txBytes => _txBytes;
  String? get activeVoicePort => _voicePort.portName;

  void setMicMuted(bool muted) {
    _micMuted = muted;
    onChanged?.call();
  }

  void setSpeakerMuted(bool muted) {
    _speakerMuted = muted;
    onChanged?.call();
  }

  void resetCounters() {
    _rxBytes = 0;
    _txBytes = 0;
    onChanged?.call();
  }

  /// Запускает двусторонний аудиомост: звуковой COM-порт модема <-> winmm.dll (динамики и микрофон ПК).
  void startVoiceBridge(String comPort) {
    stopVoiceBridge();
    lastVoiceError = null;
    if (comPort.trim().isEmpty) {
      throw StateError('Не выбран звуковой COM-порт модема.');
    }
    _voicePort.open(comPort, baudRate: 115200);
    final outOk = audio.openPcmOut();
    if (!outOk) {
      lastVoiceError = 'Не удалось открыть динамики Windows (waveOutOpen).';
    }
    _bridgeActive = true;
    _rxBytes = 0;
    _txBytes = 0;

    profiler?.logEvent(
      level: 'PROC',
      category: 'VOICE',
      subsystem: 'voice_rx_bridge',
      message: 'Запущен аудиомост winmm.dll <-> $comPort (waveOut=${outOk ? 'OK' : 'ERR'})',
    );

    // Приём голоса с модема (8кГц 16-бит моно PCM, 320 байт / 20 мс) -> динамики ПК
    _rxTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!_bridgeActive || !_voicePort.isOpen) return;
      final prof = profiler;
      final sw = (prof != null && prof.enabled) ? (Stopwatch()..start()) : null;
      final chunk = _voicePort.readAvailable(maxBytes: 3200);
      if (chunk.isNotEmpty) {
        _rxBytes += chunk.length;
        if (!_speakerMuted) {
          audio.writePcmOut(chunk);
        }
        _notifyCountersThrottled();
      }
      if (sw != null) {
        sw.stop();
        prof!.recordDuration(
          'voice_rx_bridge',
          sw.elapsedMicroseconds / 1000.0,
          detail: chunk.isEmpty ? 'idle' : 'rx ${chunk.length}B',
        );
      }
    });

    // Захват с микрофона ПК (320 байт / 20 мс) -> звуковой COM-порт модема
    final micOk = audio.startMicCapture(onChunk: (pcm) {
      if (!_bridgeActive || !_voicePort.isOpen || _micMuted || _streamingPhrase) {
        return;
      }
      final prof = profiler;
      final sw = (prof != null && prof.enabled) ? (Stopwatch()..start()) : null;
      try {
        _voicePort.writeBytes(pcm);
        _txBytes += pcm.length;
        _notifyCountersThrottled();
        if (sw != null) {
          sw.stop();
          prof!.recordDuration(
            'voice_tx_mic',
            sw.elapsedMicroseconds / 1000.0,
            detail: 'tx ${pcm.length}B',
          );
        }
      } catch (e) {
        lastVoiceError = 'Ошибка записи в голосовой порт: $e';
        if (sw != null) {
          sw.stop();
          prof!.recordDuration(
            'voice_tx_mic',
            sw.elapsedMicroseconds / 1000.0,
            detail: '$e',
            isError: true,
          );
        }
        stopVoiceBridge();
      }
    });
    if (!micOk) {
      lastVoiceError = 'Микрофон ПК недоступен (динамики работают на приём).';
      profiler?.logEvent(
        level: 'WARN',
        category: 'VOICE',
        subsystem: 'voice_tx_mic',
        message: 'Микрофон ПК недоступен при старте аудиомоста ($comPort)',
      );
    }
    onChanged?.call();
  }

  void stopVoiceBridge() {
    final wasActive = _bridgeActive;
    _rxTimer?.cancel();
    _rxTimer = null;
    if (_bridgeActive) {
      audio.stopMicCapture();
      audio.closePcmOut();
    }
    _bridgeActive = false;
    _streamingPhrase = false;
    _voicePort.close();
    if (wasActive) {
      profiler?.logEvent(
        level: 'PROC',
        category: 'VOICE',
        subsystem: 'voice_rx_bridge',
        message: 'Аудиомост остановлен (итог TX=$_txBytes B, RX=$_rxBytes B)',
      );
    }
    onChanged?.call();
  }

  // ---------------- Библиотека фраз (UserData/Sounds) ----------------

  Future<List<VoicePhraseItem>> listPhrases() async {
    await AppPaths.ensureDirectories();
    final dir = Directory(AppPaths.soundsDir);
    final items = <VoicePhraseItem>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.toLowerCase().endsWith('.wav')) {
        final stat = await entity.stat();
        items.add(VoicePhraseItem(
          name: p.basename(entity.path),
          path: entity.path,
          sizeBytes: stat.size,
        ));
      }
    }
    items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return items;
  }

  bool startRecordPhrase() {
    if (_bridgeActive) return false;
    final ok = audio.startMicCapture();
    onChanged?.call();
    return ok;
  }

  Future<String?> stopAndSavePhrase(String name) async {
    final pcm = audio.stopMicCapture();
    onChanged?.call();
    if (pcm.isEmpty) return null;
    await AppPaths.ensureDirectories();
    final safe = name.trim().replaceAll(RegExp(r'[^\wа-яА-ЯёЁ\- ]'), '_');
    final fileName =
        (safe.isEmpty ? 'phrase_${DateTime.now().millisecondsSinceEpoch}' : safe) +
            '.wav';
    final outPath = p.join(AppPaths.soundsDir, fileName);
    await File(outPath).writeAsBytes(WinmmAudio.wrapPcm8kToWav(pcm));
    return outPath;
  }

  Future<String> importWavFile(String sourcePath) async {
    await AppPaths.ensureDirectories();
    final destName = p.basename(sourcePath);
    final destPath = p.join(AppPaths.soundsDir, destName);
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> deletePhrase(String filePath) async {
    final f = File(filePath);
    if (await f.exists()) {
      await f.delete();
    }
  }

  void previewPhrase(String filePath) {
    audio.playWavFile(filePath);
  }

  /// Воспроизводит WAV-фразу непосредственно в активный голосовой звонок через звуковой COM-порт модема.
  Future<void> playPhraseIntoCall({
    required String filePathOrName,
    required String voiceComPort,
  }) async {
    final file = File(filePathOrName).existsSync()
        ? File(filePathOrName)
        : File(p.join(AppPaths.soundsDir, filePathOrName));
    if (!await file.exists()) {
      throw StateError('Аудиофайл фразы не найден: $filePathOrName');
    }

    final wavBytes = await file.readAsBytes();
    final pcm8k = WinmmAudio.extract8kMonoPcmFromWav(wavBytes);
    if (pcm8k.isEmpty) return;

    final openedTemporarily = !_voicePort.isOpen;
    if (openedTemporarily) {
      if (voiceComPort.trim().isEmpty) {
        throw StateError('Не задан звуковой COM-порт для воспроизведения фразы.');
      }
      _voicePort.open(voiceComPort, baudRate: 115200);
    }

    _streamingPhrase = true;
    onChanged?.call();
    try {
      // 320 байт = 20 мс при 8000 Гц 16-бит моно PCM
      const frameSize = 320;
      for (var off = 0; off < pcm8k.length; off += frameSize) {
        if (!_voicePort.isOpen) break;
        final end =
            (off + frameSize < pcm8k.length) ? off + frameSize : pcm8k.length;
        final frame = Uint8List.sublistView(pcm8k, off, end);
        _voicePort.writeBytes(frame);
        _txBytes += frame.length;
        await Future.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _streamingPhrase = false;
      if (openedTemporarily) {
        _voicePort.close();
      }
      onChanged?.call();
    }
  }

  void dispose() {
    stopVoiceBridge();
  }
}
