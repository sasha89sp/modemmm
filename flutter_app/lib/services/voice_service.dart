import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
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

  Timer? _rxTimer;
  bool _bridgeActive = false;
  bool _micMuted = false;
  bool _speakerMuted = false;
  bool _streamingPhrase = false;
  int _rxBytes = 0;
  int _txBytes = 0;

  VoiceService(this.audio, {this.onChanged});

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
    if (comPort.trim().isEmpty) {
      throw StateError('Не выбран звуковой COM-порт модема.');
    }
    _voicePort.open(comPort, baudRate: 115200, readTimeoutMs: 25);
    audio.openPcmOut();
    _bridgeActive = true;
    _rxBytes = 0;
    _txBytes = 0;

    // Приём голоса с модема -> динамики ПК
    _rxTimer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (!_bridgeActive || !_voicePort.isOpen) return;
      final chunk = _voicePort.readAvailable(maxBytes: 1600);
      if (chunk.isNotEmpty) {
        _rxBytes += chunk.length;
        if (!_speakerMuted) {
          audio.writePcmOut(chunk);
        }
        onChanged?.call();
      }
    });

    // Захват с микрофона ПК -> звуковой COM-порт модема
    audio.startMicCapture(onChunk: (pcm) {
      if (!_bridgeActive || !_voicePort.isOpen || _micMuted || _streamingPhrase) {
        return;
      }
      try {
        _voicePort.writeBytes(pcm);
        _txBytes += pcm.length;
        onChanged?.call();
      } catch (_) {
        stopVoiceBridge();
      }
    });
    onChanged?.call();
  }

  void stopVoiceBridge() {
    _rxTimer?.cancel();
    _rxTimer = null;
    if (_bridgeActive) {
      audio.stopMicCapture();
      audio.closePcmOut();
    }
    _bridgeActive = false;
    _streamingPhrase = false;
    _voicePort.close();
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
      _voicePort.open(voiceComPort, baudRate: 115200, readTimeoutMs: 25);
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
