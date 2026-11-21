import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// Win32 WAVEFORMATEX (ровно 18 байт)
@Packed(2)
final class WAVEFORMATEX extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

// Win32 WAVEHDR (48 байт на x64 Windows)
final class WAVEHDR extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<WAVEHDR> lpNext;
  @IntPtr()
  external int reserved;
}

typedef _PlaySoundWNative = Int32 Function(
  Pointer<Void> pszSound,
  IntPtr hmod,
  Uint32 fdwSound,
);
typedef _PlaySoundWDart = int Function(
  Pointer<Void> pszSound,
  int hmod,
  int fdwSound,
);

typedef _WaveOutOpenNative = Uint32 Function(
  Pointer<IntPtr> phwo,
  Uint32 uDeviceID,
  Pointer<WAVEFORMATEX> pwfx,
  IntPtr dwCallback,
  IntPtr dwInstance,
  Uint32 fdwOpen,
);
typedef _WaveOutOpenDart = int Function(
  Pointer<IntPtr> phwo,
  int uDeviceID,
  Pointer<WAVEFORMATEX> pwfx,
  int dwCallback,
  int dwInstance,
  int fdwOpen,
);

typedef _WaveOutHdrNative = Uint32 Function(
  IntPtr hwo,
  Pointer<WAVEHDR> pwh,
  Uint32 cbwh,
);
typedef _WaveOutHdrDart = int Function(
  int hwo,
  Pointer<WAVEHDR> pwh,
  int cbwh,
);

typedef _WaveOutSimpleNative = Uint32 Function(IntPtr hwo);
typedef _WaveOutSimpleDart = int Function(int hwo);

typedef _WaveInOpenNative = Uint32 Function(
  Pointer<IntPtr> phwi,
  Uint32 uDeviceID,
  Pointer<WAVEFORMATEX> pwfx,
  IntPtr dwCallback,
  IntPtr dwInstance,
  Uint32 fdwOpen,
);
typedef _WaveInOpenDart = int Function(
  Pointer<IntPtr> phwi,
  int uDeviceID,
  Pointer<WAVEFORMATEX> pwfx,
  int dwCallback,
  int dwInstance,
  int fdwOpen,
);

typedef _WaveInHdrNative = Uint32 Function(
  IntPtr hwi,
  Pointer<WAVEHDR> pwh,
  Uint32 cbwh,
);
typedef _WaveInHdrDart = int Function(
  int hwi,
  Pointer<WAVEHDR> pwh,
  int cbwh,
);

typedef _WaveInSimpleNative = Uint32 Function(IntPtr hwi);
typedef _WaveInSimpleDart = int Function(int hwi);

/// Нативный звуковой движок Windows через winmm.dll (dart:ffi):
/// - синтезированная мелодия оповещения SMS с регулировкой громкости;
/// - проигрывание WAV-файлов и потокового 8кГц 16-бит PCM на динамики ПК;
/// - запись с микрофона ПК в 8кГц 16-бит PCM (для фраз и передачи в голосовой порт Huawei).
class WinmmAudio {
  static const int _waveMapper = 0xFFFFFFFF;
  static const int _sndAsync = 0x0001;
  static const int _sndMemory = 0x0004;
  static const int _sndFilename = 0x00020000;
  static const int _whdrDone = 0x00000001;

  late final DynamicLibrary _winmm;
  late final _PlaySoundWDart _playSoundW;
  late final _WaveOutOpenDart _waveOutOpen;
  late final _WaveOutHdrDart _waveOutPrepareHeader;
  late final _WaveOutHdrDart _waveOutWrite;
  late final _WaveOutHdrDart _waveOutUnprepareHeader;
  late final _WaveOutSimpleDart _waveOutReset;
  late final _WaveOutSimpleDart _waveOutClose;

  late final _WaveInOpenDart _waveInOpen;
  late final _WaveInHdrDart _waveInPrepareHeader;
  late final _WaveInHdrDart _waveInAddBuffer;
  late final _WaveInHdrDart _waveInUnprepareHeader;
  late final _WaveInSimpleDart _waveInStart;
  late final _WaveInSimpleDart _waveInStop;
  late final _WaveInSimpleDart _waveInReset;
  late final _WaveInSimpleDart _waveInClose;

  Pointer<Uint8>? _lastChimeBuf;

  // Streaming waveOut (8kHz 16-bit mono PCM) с безопасным освобождением по WHDR_DONE
  int _hWaveOut = 0;
  final List<(Pointer<WAVEHDR>, Pointer<Uint8>)> _outQueue = [];

  // Streaming waveIn (8kHz 16-bit mono PCM, 4 ротируемых буфера по 320 байт = 20 мс)
  int _hWaveIn = 0;
  bool _recording = false;
  final List<int> _recordedPcm = [];
  Timer? _waveInPollTimer;
  final List<(Pointer<WAVEHDR>, Pointer<Uint8>)> _inRing = [];
  void Function(Uint8List pcm)? _onMicChunk;

  bool get isRecording => _recording;
  bool get isOutOpen => _hWaveOut != 0;

  WinmmAudio() {
    if (!Platform.isWindows) return;
    _winmm = DynamicLibrary.open('winmm.dll');
    _playSoundW =
        _winmm.lookupFunction<_PlaySoundWNative, _PlaySoundWDart>('PlaySoundW');
    _waveOutOpen = _winmm
        .lookupFunction<_WaveOutOpenNative, _WaveOutOpenDart>('waveOutOpen');
    _waveOutPrepareHeader =
        _winmm.lookupFunction<_WaveOutHdrNative, _WaveOutHdrDart>(
            'waveOutPrepareHeader');
    _waveOutWrite = _winmm
        .lookupFunction<_WaveOutHdrNative, _WaveOutHdrDart>('waveOutWrite');
    _waveOutUnprepareHeader =
        _winmm.lookupFunction<_WaveOutHdrNative, _WaveOutHdrDart>(
            'waveOutUnprepareHeader');
    _waveOutReset = _winmm.lookupFunction<_WaveOutSimpleNative, _WaveOutSimpleDart>(
        'waveOutReset');
    _waveOutClose = _winmm.lookupFunction<_WaveOutSimpleNative, _WaveOutSimpleDart>(
        'waveOutClose');

    _waveInOpen = _winmm
        .lookupFunction<_WaveInOpenNative, _WaveInOpenDart>('waveInOpen');
    _waveInPrepareHeader =
        _winmm.lookupFunction<_WaveInHdrNative, _WaveInHdrDart>(
            'waveInPrepareHeader');
    _waveInAddBuffer = _winmm
        .lookupFunction<_WaveInHdrNative, _WaveInHdrDart>('waveInAddBuffer');
    _waveInUnprepareHeader =
        _winmm.lookupFunction<_WaveInHdrNative, _WaveInHdrDart>(
            'waveInUnprepareHeader');
    _waveInStart = _winmm
        .lookupFunction<_WaveInSimpleNative, _WaveInSimpleDart>('waveInStart');
    _waveInStop = _winmm
        .lookupFunction<_WaveInSimpleNative, _WaveInSimpleDart>('waveInStop');
    _waveInReset = _winmm
        .lookupFunction<_WaveInSimpleNative, _WaveInSimpleDart>('waveInReset');
    _waveInClose = _winmm
        .lookupFunction<_WaveInSimpleNative, _WaveInSimpleDart>('waveInClose');
  }

  /// Воспроизводит приятную двухтональную мелодию оповещения SMS через winmm.dll.
  void playSmsNotification({double volume = 0.8}) {
    if (!Platform.isWindows || volume <= 0.01) return;
    final wav = _synthesizeSmsChimeWav(volume.clamp(0.0, 1.0).toDouble());
    if (_lastChimeBuf != null) {
      calloc.free(_lastChimeBuf!);
      _lastChimeBuf = null;
    }
    final ptr = calloc<Uint8>(wav.length);
    ptr.asTypedList(wav.length).setAll(0, wav);
    _lastChimeBuf = ptr;
    _playSoundW(ptr.cast<Void>(), 0, _sndMemory | _sndAsync);
  }

  /// Проигрывает WAV-файл с диска через winmm.dll.
  void playWavFile(String filePath) {
    if (!Platform.isWindows || !File(filePath).existsSync()) return;
    final pathPtr = filePath.toNativeUtf16();
    try {
      _playSoundW(pathPtr.cast<Void>(), 0, _sndFilename | _sndAsync);
    } finally {
      calloc.free(pathPtr);
    }
  }

  void stopPlayback() {
    if (!Platform.isWindows) return;
    _playSoundW(nullptr, 0, 0);
  }

  /// Открывает потоковый вывод 8кГц 16-бит моно PCM (формат голоса Huawei E173).
  bool openPcmOut() {
    if (!Platform.isWindows) return false;
    closePcmOut();
    final phwo = calloc<IntPtr>();
    final fmt = calloc<WAVEFORMATEX>();
    try {
      _fill8kMonoFormat(fmt);
      final res = _waveOutOpen(phwo, _waveMapper, fmt, 0, 0, 0);
      if (res == 0) {
        _hWaveOut = phwo.value;
        return true;
      }
      return false;
    } finally {
      calloc.free(phwo);
      calloc.free(fmt);
    }
  }

  void _reclaimCompletedOutBuffers() {
    if (_hWaveOut == 0 || _outQueue.isEmpty) return;
    _outQueue.removeWhere((pair) {
      final hdr = pair.$1;
      final buf = pair.$2;
      if ((hdr.ref.dwFlags & _whdrDone) != 0) {
        _waveOutUnprepareHeader(_hWaveOut, hdr, sizeOf<WAVEHDR>());
        calloc.free(buf);
        calloc.free(hdr);
        return true;
      }
      return false;
    });
  }

  void writePcmOut(Uint8List pcm) {
    if (!Platform.isWindows || _hWaveOut == 0 || pcm.isEmpty) return;
    _reclaimCompletedOutBuffers();
    // Защита от накопления слишком длинной очереди (если драйвер подвис)
    if (_outQueue.length > 64) return;

    final buf = calloc<Uint8>(pcm.length);
    final hdr = calloc<WAVEHDR>();
    buf.asTypedList(pcm.length).setAll(0, pcm);
    hdr.ref.lpData = buf;
    hdr.ref.dwBufferLength = pcm.length;
    hdr.ref.dwFlags = 0;

    if (_waveOutPrepareHeader(_hWaveOut, hdr, sizeOf<WAVEHDR>()) == 0) {
      if (_waveOutWrite(_hWaveOut, hdr, sizeOf<WAVEHDR>()) == 0) {
        _outQueue.add((hdr, buf));
      } else {
        _waveOutUnprepareHeader(_hWaveOut, hdr, sizeOf<WAVEHDR>());
        calloc.free(buf);
        calloc.free(hdr);
      }
    } else {
      calloc.free(buf);
      calloc.free(hdr);
    }
  }

  void closePcmOut() {
    if (_hWaveOut != 0) {
      _waveOutReset(_hWaveOut);
      for (final pair in _outQueue) {
        _waveOutUnprepareHeader(_hWaveOut, pair.$1, sizeOf<WAVEHDR>());
        calloc.free(pair.$2);
        calloc.free(pair.$1);
      }
      _outQueue.clear();
      _waveOutClose(_hWaveOut);
      _hWaveOut = 0;
    }
  }

  /// Запускает непрерывный захват с микрофона ПК: 4 ротируемых буфера по 320 байт (20 мс @ 8кГц 16-бит моно).
  bool startMicCapture({void Function(Uint8List pcm)? onChunk}) {
    if (!Platform.isWindows) return false;
    stopMicCapture();
    _recordedPcm.clear();
    _onMicChunk = onChunk;

    final phwi = calloc<IntPtr>();
    final fmt = calloc<WAVEFORMATEX>();
    try {
      _fill8kMonoFormat(fmt);
      final res = _waveInOpen(phwi, _waveMapper, fmt, 0, 0, 0);
      if (res != 0) return false;
      _hWaveIn = phwi.value;
    } finally {
      calloc.free(phwi);
      calloc.free(fmt);
    }

    // Huawei E173 (^CVOICE:0,8000,16,20) работает фреймами строго 320 байт / 20 мс
    const chunkSize = 320;
    const bufferCount = 4;
    for (var i = 0; i < bufferCount; i++) {
      final buf = calloc<Uint8>(chunkSize);
      final hdr = calloc<WAVEHDR>();
      hdr.ref.lpData = buf;
      hdr.ref.dwBufferLength = chunkSize;
      hdr.ref.dwFlags = 0;
      _waveInPrepareHeader(_hWaveIn, hdr, sizeOf<WAVEHDR>());
      _waveInAddBuffer(_hWaveIn, hdr, sizeOf<WAVEHDR>());
      _inRing.add((hdr, buf));
    }

    _waveInStart(_hWaveIn);
    _recording = true;

    _waveInPollTimer = Timer.periodic(const Duration(milliseconds: 15), (_) {
      if (!_recording || _hWaveIn == 0 || _inRing.isEmpty) return;
      for (final pair in _inRing) {
        final hdr = pair.$1;
        final buf = pair.$2;
        if ((hdr.ref.dwFlags & _whdrDone) != 0) {
          final recorded = hdr.ref.dwBytesRecorded;
          if (recorded > 0) {
            final bytes = Uint8List.fromList(buf.asTypedList(recorded));
            if (_onMicChunk == null) {
              // Храним буфер в RAM только при записи WAV-фразы (не при бесконечном звонке)
              _recordedPcm.addAll(bytes);
            } else {
              _onMicChunk?.call(bytes);
            }
          }
          _waveInUnprepareHeader(_hWaveIn, hdr, sizeOf<WAVEHDR>());
          hdr.ref.dwFlags = 0;
          hdr.ref.dwBytesRecorded = 0;
          _waveInPrepareHeader(_hWaveIn, hdr, sizeOf<WAVEHDR>());
          _waveInAddBuffer(_hWaveIn, hdr, sizeOf<WAVEHDR>());
        }
      }
    });
    return true;
  }

  /// Останавливает захват микрофона и возвращает собранные PCM-данные (8кГц 16-бит моно).
  Uint8List stopMicCapture() {
    _waveInPollTimer?.cancel();
    _waveInPollTimer = null;
    _recording = false;
    _onMicChunk = null;

    if (_hWaveIn != 0) {
      _waveInStop(_hWaveIn);
      _waveInReset(_hWaveIn);
      for (final pair in _inRing) {
        _waveInUnprepareHeader(_hWaveIn, pair.$1, sizeOf<WAVEHDR>());
        calloc.free(pair.$2);
        calloc.free(pair.$1);
      }
      _inRing.clear();
      _waveInClose(_hWaveIn);
      _hWaveIn = 0;
    } else {
      for (final pair in _inRing) {
        calloc.free(pair.$2);
        calloc.free(pair.$1);
      }
      _inRing.clear();
    }
    return Uint8List.fromList(_recordedPcm);
  }

  void dispose() {
    stopMicCapture();
    closePcmOut();
    stopPlayback();
    if (_lastChimeBuf != null) {
      calloc.free(_lastChimeBuf!);
      _lastChimeBuf = null;
    }
  }

  static void _fill8kMonoFormat(Pointer<WAVEFORMATEX> fmt) {
    fmt.ref.wFormatTag = 1; // WAVE_FORMAT_PCM
    fmt.ref.nChannels = 1;
    fmt.ref.nSamplesPerSec = 8000;
    fmt.ref.wBitsPerSample = 16;
    fmt.ref.nBlockAlign = 2;
    fmt.ref.nAvgBytesPerSec = 16000;
    fmt.ref.cbSize = 0;
  }

  /// Упаковывает сырой 8кГц 16-бит моно PCM в полноценный WAV-файл.
  static Uint8List wrapPcm8kToWav(Uint8List pcm) {
    final dataLen = pcm.length;
    final out = ByteData(44 + dataLen);
    void writeStr(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        out.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    out.setUint32(4, 36 + dataLen, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little); // PCM
    out.setUint16(22, 1, Endian.little); // mono
    out.setUint32(24, 8000, Endian.little); // 8kHz
    out.setUint32(28, 16000, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    out.setUint32(40, dataLen, Endian.little);

    final bytes = out.buffer.asUint8List();
    bytes.setAll(44, pcm);
    return bytes;
  }

  /// Читает любой PCM WAV-файл и пересэмплирует его в 8кГц 16-бит моно PCM для модема Huawei E173.
  static Uint8List extract8kMonoPcmFromWav(Uint8List wavBytes) {
    if (wavBytes.length < 44) return Uint8List(0);
    final bd = ByteData.sublistView(wavBytes);
    final channels = bd.getUint16(22, Endian.little);
    final sampleRate = bd.getUint32(24, Endian.little);
    final bitsPerSample = bd.getUint16(34, Endian.little);

    // Ищем чанк 'data'
    var offset = 12;
    var dataOffset = 44;
    var dataLength = wavBytes.length - 44;
    while (offset + 8 <= wavBytes.length) {
      final id = String.fromCharCodes(wavBytes.sublist(offset, offset + 4));
      final chunkSize = bd.getUint32(offset + 4, Endian.little);
      if (id == 'data') {
        dataOffset = offset + 8;
        dataLength = math.min(chunkSize, wavBytes.length - dataOffset);
        break;
      }
      offset += 8 + chunkSize;
    }

    if (sampleRate == 8000 && channels == 1 && bitsPerSample == 16) {
      return Uint8List.sublistView(wavBytes, dataOffset, dataOffset + dataLength);
    }

    // Конвертация в моно 16-бит и линейный ресэмплинг к 8000 Гц
    final int bytesPerSample = math.max<int>(1, bitsPerSample ~/ 8);
    final int frameBytes = bytesPerSample * math.max<int>(1, channels);
    final int totalFrames = dataLength ~/ frameBytes;
    if (totalFrames <= 0 || sampleRate <= 0) return Uint8List(0);

    final monoSamples = Int16List(totalFrames);
    for (var i = 0; i < totalFrames; i++) {
      final int base = dataOffset + i * frameBytes;
      int sample;
      if (bitsPerSample == 16 && base + 1 < wavBytes.length) {
        sample = bd.getInt16(base, Endian.little);
      } else {
        sample = (wavBytes[base] - 128) * 256;
      }
      monoSamples[i] = sample;
    }

    final targetFrames = (totalFrames * 8000 / sampleRate).round();
    final out = ByteData(targetFrames * 2);
    for (var i = 0; i < targetFrames; i++) {
      final srcIdx =
          (i * sampleRate / 8000).floor().clamp(0, monoSamples.length - 1).toInt();
      out.setInt16(i * 2, monoSamples[srcIdx], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// Генерирует двухтональный звонкий сигнал SMS (880 Гц -> 1175 Гц) в памяти.
  static Uint8List _synthesizeSmsChimeWav(double volume) {
    const sr = 22050;
    const totalSamples = 9261;
    final pcm = ByteData(totalSamples * 2);
    final amp = (24000 * volume).round();

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sr;
      final freq = t < 0.16 ? 880.0 : 1174.66;
      final localT = t < 0.16 ? t : (t - 0.16);
      final env = math.exp(-localT * 9.0);
      final s = (math.sin(2 * math.pi * freq * t) * amp * env).round();
      pcm.setInt16(i * 2, s.clamp(-32767, 32767).toInt(), Endian.little);
    }

    final pcmBytes = pcm.buffer.asUint8List();
    final header = ByteData(44 + pcmBytes.length);
    void writeStr(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    header.setUint32(4, 36 + pcmBytes.length, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sr, Endian.little);
    header.setUint32(28, sr * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    header.setUint32(40, pcmBytes.length, Endian.little);
    final result = header.buffer.asUint8List();
    result.setAll(44, pcmBytes);
    return result;
  }
}
