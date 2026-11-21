import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../services/modem_controller.dart';

class CallsTab extends StatefulWidget {
  final ModemController controller;

  const CallsTab({super.key, required this.controller});

  @override
  State<CallsTab> createState() => _CallsTabState();
}

class _CallsTabState extends State<CallsTab> {
  final TextEditingController _dialCtrl = TextEditingController();
  final TextEditingController _dtmfCtrl = TextEditingController();

  ModemController get c => widget.controller;

  @override
  void dispose() {
    _dialCtrl.dispose();
    _dtmfCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _dial() async {
    final phoneNumber = _dialCtrl.text.trim();
    if (phoneNumber.isEmpty || !c.snapshot.connected) return;
    c.callStateBanner = 'Набор $phoneNumber...';
    setState(() {});
    final (ok, detail) = await c.modem.dialVoiceDetailed(phoneNumber);
    c.db.logOperation('Звонок', 'Исходящий на $phoneNumber', ok ? 'Набор' : 'Ошибка', detail);
    if (!ok) {
      c.callStateBanner = '';
      _snack('Звонок отклонён модемом: $detail');
    } else {
      c.callStateBanner = 'Вызов $phoneNumber (ожидание ^CONN)...';
      final voicePort = c.settings.preferredVoicePort;
      if (voicePort.isNotEmpty &&
          voicePort != c.snapshot.port &&
          !c.voice.isBridgeActive) {
        try {
          c.voice.startVoiceBridge(voicePort);
        } catch (e) {
          _snack('Звонок набран, но звуковой порт не открыт: $e');
        }
      }
    }
    await c.refreshActiveCalls();
    if (mounted) setState(() {});
  }

  Future<void> _hangup() async {
    await c.modem.hangupCall();
    c.voice.stopVoiceBridge();
    c.incomingCallerNumber = null;
    c.callStateBanner = '';
    c.db.logOperation('Звонок', 'Завершение вызова', 'OK');
    await c.refreshActiveCalls();
    if (mounted) setState(() {});
  }

  Future<void> _stopRecordingAndPromptName() async {
    final nameCtrl = TextEditingController(
      text: 'Фраза_${DateTime.now().hour}_${DateTime.now().minute}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохранить записанную фразу'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Имя файла (без .wav)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Сохранить WAV'),
          ),
        ],
      ),
    );
    final saved = await c.voice.stopAndSavePhrase(name ?? '');
    if (saved != null) {
      await c.refreshVoicePhrases();
      _snack('Фраза сохранена: $saved');
    } else {
      _snack('Запись пуста или отменена.');
    }
  }

  Future<void> _importWav() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    final dest = await c.voice.importWavFile(path);
    await c.refreshVoicePhrases();
    _snack('Импортировано в UserData/Sounds: $dest');
  }

  @override
  Widget build(BuildContext context) {
    final portConnected = c.snapshot.connected;
    final connected = portConnected && !c.snapshot.simMissing;
    final voicePortItems = <DropdownMenuItem<String>>[];
    for (final p in c.ports) {
      voicePortItems.add(DropdownMenuItem(
        value: p.port,
        child: Text(
          p.isHuaweiVoiceCandidate ? '[Звуковой] ${p.displayLabel}' : p.displayLabel,
          overflow: TextOverflow.ellipsis,
        ),
      ));
    }
    final rememberedVoice = c.settings.preferredVoicePort;
    if (rememberedVoice.isNotEmpty &&
        !c.ports.any((p) => p.port == rememberedVoice)) {
      voicePortItems.insert(
        0,
        DropdownMenuItem(
          value: rememberedVoice,
          child: Text('$rememberedVoice (сохранён, временно отсутствует)'),
        ),
      );
    }
    final sameAsMainPort =
        rememberedVoice.isNotEmpty && rememberedVoice == c.snapshot.port;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Левая колонка: управление звонками, DTMF и аудиомост winmm.dll
          Expanded(
            flex: 3,
            child: ListView(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Управление голосовыми вызовами',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                            ),
                            const Spacer(),
                            if (c.callStateBanner.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  c.callStateBanner,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF166534),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Диагностика голосовой функции прошивки (AT^CVOICE?)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: c.voiceCapabilityEnabled == false
                                ? const Color(0xFFFEF3C7)
                                : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: c.voiceCapabilityEnabled == false
                                  ? const Color(0xFFF59E0B)
                                  : const Color(0xFFE2E8F0),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                c.voiceCapabilityEnabled == true
                                    ? Icons.check_circle_outline
                                    : (c.voiceCapabilityEnabled == false
                                        ? Icons.warning_amber_rounded
                                        : Icons.info_outline),
                                size: 17,
                                color: c.voiceCapabilityEnabled == true
                                    ? const Color(0xFF166534)
                                    : (c.voiceCapabilityEnabled == false
                                        ? const Color(0xFFB45309)
                                        : Colors.black54),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Прошивка голоса (AT^CVOICE?): ${c.voiceCapabilityStatus}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton(
                                onPressed: portConnected ? c.checkVoiceCapability : null,
                                child: const Text('Проверить', style: TextStyle(fontSize: 12)),
                              ),
                              if (c.voiceCapabilityEnabled == false)
                                TextButton(
                                  onPressed: portConnected
                                      ? () async {
                                          final (ok, raw) =
                                              await c.tryEnableVoiceCapability();
                                          _snack(ok
                                              ? 'Голос включён (AT^CVOICE=0 -> OK).'
                                              : 'Модем отклонил AT^CVOICE=0: $raw');
                                        }
                                      : null,
                                  child: const Text('Включить AT^CVOICE=0',
                                      style: TextStyle(fontSize: 12)),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _dialCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Номер телефона',
                                  hintText: '+79991234567 или 0890',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: connected ? _dial : null,
                              icon: const Icon(Icons.call, size: 18),
                              label: const Text('Позвонить'),
                            ),
                            const SizedBox(width: 6),
                            FilledButton.tonalIcon(
                              onPressed: portConnected
                                  ? () async {
                                      await c.modem.answerCall();
                                      if (rememberedVoice.isNotEmpty &&
                                          rememberedVoice != c.snapshot.port &&
                                          !c.voice.isBridgeActive) {
                                        try {
                                          c.voice.startVoiceBridge(rememberedVoice);
                                        } catch (_) {}
                                      }
                                      await c.refreshActiveCalls();
                                    }
                                  : null,
                              icon: const Icon(Icons.call_received, size: 18),
                              label: const Text('Ответить'),
                            ),
                            const SizedBox(width: 6),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFDC2626),
                              ),
                              onPressed: portConnected ? _hangup : null,
                              icon: const Icon(Icons.call_end, size: 18),
                              label: const Text('Сбросить'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Text('DTMF (AT+VTS):',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: _dtmfCtrl,
                                decoration: const InputDecoration(
                                  hintText: '123#',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: portConnected
                                  ? () => c.modem.sendDtmf(_dtmfCtrl.text)
                                  : null,
                              child: const Text('Отправить'),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#']
                                    .map((d) => SizedBox(
                                          width: 34,
                                          height: 30,
                                          child: OutlinedButton(
                                            style: OutlinedButton.styleFrom(
                                              padding: EdgeInsets.zero,
                                            ),
                                            onPressed: portConnected
                                                ? () => c.modem.sendDtmf(d)
                                                : null,
                                            child: Text(d),
                                          ),
                                        ))
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Звуковой COM-порт и аудиомост winmm.dll
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Звуковой COM-порт Huawei E173 (winmm.dll · AT^DDSETEX=2)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: rememberedVoice.isNotEmpty
                                    ? rememberedVoice
                                    : null,
                                decoration: const InputDecoration(
                                  labelText: 'Звуковой COM-порт (выберите 3G Application Interface)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: voicePortItems,
                                onChanged: c.voice.isBridgeActive
                                    ? null
                                    : (v) async {
                                        c.settings.preferredVoicePort = v ?? '';
                                        await c.saveSettings();
                                        setState(() {});
                                      },
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: portConnected
                                  ? () async {
                                      final ok =
                                          await c.modem.enableHuaweiVoiceChannel();
                                      _snack(ok
                                          ? 'AT^DDSETEX=2 -> OK (аудиоканал открыт)'
                                          : 'Модем отклонил AT^DDSETEX=2');
                                    }
                                  : null,
                              child: const Text('AT^DDSETEX=2'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: rememberedVoice.isEmpty || sameAsMainPort
                                  ? null
                                  : () async {
                                      if (c.voice.isBridgeActive) {
                                        c.voice.stopVoiceBridge();
                                      } else {
                                        try {
                                          if (c.snapshot.connected) {
                                            await c.modem.enableHuaweiVoiceChannel();
                                          }
                                          c.voice.startVoiceBridge(rememberedVoice);
                                        } catch (e) {
                                          _snack('Ошибка аудиомоста: $e');
                                        }
                                      }
                                      setState(() {});
                                    },
                              icon: Icon(c.voice.isBridgeActive
                                  ? Icons.hearing_disabled
                                  : Icons.headset_mic),
                              label: Text(c.voice.isBridgeActive
                                  ? 'Остановить аудио'
                                  : 'Открыть аудиомост'),
                            ),
                          ],
                        ),
                        if (sameAsMainPort) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Внимание: выбран тот же COM-порт, что и основной PC UI. Для голоса выберите отдельный порт (3G Application Interface).',
                            style: TextStyle(fontSize: 12, color: Color(0xFFB45309)),
                          ),
                        ],
                        if (c.voice.lastVoiceError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Аудио: ${c.voice.lastVoiceError}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
                          ),
                        ],
                        if (c.voice.isBridgeActive &&
                            c.voice.txBytes > 32000 &&
                            c.voice.rxBytes == 0) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Подсказка: TX идёт, но RX = 0 байт. Проверьте, что выбран порт «3G Application Interface» (не 3G Modem), голос включён (AT^CVOICE?=0) и нажата кнопка AT^DDSETEX=2 после ответа абонента.',
                            style: TextStyle(fontSize: 12, color: Color(0xFFB45309)),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilterChip(
                              selected: c.voice.isMicMuted,
                              onSelected: (v) => c.voice.setMicMuted(v),
                              avatar: Icon(
                                c.voice.isMicMuted ? Icons.mic_off : Icons.mic,
                                size: 17,
                              ),
                              label: Text(c.voice.isMicMuted
                                  ? 'Микрофон выкл.'
                                  : 'Микрофон вкл.'),
                            ),
                            FilterChip(
                              selected: c.voice.isSpeakerMuted,
                              onSelected: (v) => c.voice.setSpeakerMuted(v),
                              avatar: Icon(
                                c.voice.isSpeakerMuted
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                                size: 17,
                              ),
                              label: Text(c.voice.isSpeakerMuted
                                  ? 'Динамики выкл.'
                                  : 'Динамики вкл.'),
                            ),
                            Text(
                              'TX: ${c.voice.txBytes} байт  |  RX: ${c.voice.rxBytes} байт',
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextButton(
                              onPressed: c.voice.resetCounters,
                              child: const Text('Сбросить счётчики'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Активные вызовы (AT+CLCC)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Активные вызовы (AT+CLCC)',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                            const Spacer(),
                            OutlinedButton.icon(
                              onPressed: connected ? c.refreshActiveCalls : null,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Обновить'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (c.activeCalls.isEmpty)
                          const Text(
                            'Активных звонков нет.',
                            style: TextStyle(fontSize: 12, color: Colors.black54),
                          )
                        else
                          ...c.activeCalls.map(
                            (call) => ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                call.dir == 0 ? Icons.call_made : Icons.call_received,
                              ),
                              title: Text(call.number.isEmpty ? 'Скрытый номер' : call.number),
                              subtitle: Text(call.stateLabel),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 14),

          // Правая колонка: библиотека голосовых фраз (UserData/Sounds)
          Expanded(
            flex: 2,
            child: Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Библиотека фраз (UserData/Sounds)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!c.voice.isRecordingPhrase)
                              FilledButton.tonalIcon(
                                onPressed: c.voice.isBridgeActive
                                    ? null
                                    : () {
                                        final ok = c.voice.startRecordPhrase();
                                        if (!ok) {
                                          _snack('Не удалось открыть микрофон Windows.');
                                        }
                                        setState(() {});
                                      },
                                icon: const Icon(Icons.fiber_manual_record,
                                    color: Color(0xFFDC2626), size: 17),
                                label: const Text('Записать с микрофона'),
                              )
                            else
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFDC2626),
                                ),
                                onPressed: _stopRecordingAndPromptName,
                                icon: const Icon(Icons.stop, size: 17),
                                label: const Text('Стоп и сохранить WAV'),
                              ),
                            OutlinedButton.icon(
                              onPressed: _importWav,
                              icon: const Icon(Icons.upload_file, size: 17),
                              label: const Text('Импорт WAV'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: c.voicePhrases.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                'Запишите фразу с микрофона или импортируйте WAV-файл.\nФразы можно проигрывать в звонок вручную и в сценариях.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: c.voicePhrases.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, idx) {
                              final item = c.voicePhrases[idx];
                              final kb = (item.sizeBytes / 1024).toStringAsFixed(1);
                              return ListTile(
                                dense: true,
                                title: Text(item.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600, fontSize: 13)),
                                subtitle: Text('$kb КБ'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Прослушать на ПК',
                                      icon: const Icon(Icons.play_arrow, size: 20),
                                      onPressed: () =>
                                          c.voice.previewPhrase(item.path),
                                    ),
                                    IconButton(
                                      tooltip: 'Воспроизвести в звонок',
                                      icon: const Icon(Icons.record_voice_over,
                                          size: 19),
                                      onPressed: rememberedVoice.isEmpty
                                          ? null
                                          : () async {
                                              try {
                                                await c.voice.playPhraseIntoCall(
                                                  filePathOrName: item.path,
                                                  voiceComPort: rememberedVoice,
                                                );
                                                _snack(
                                                    'Фраза «${item.name}» воспроизведена в звонок.');
                                              } catch (e) {
                                                _snack('Ошибка воспроизведения: $e');
                                              }
                                            },
                                    ),
                                    IconButton(
                                      tooltip: 'Удалить',
                                      icon: const Icon(Icons.delete_outline,
                                          size: 19),
                                      onPressed: () async {
                                        await c.voice.deletePhrase(item.path);
                                        await c.refreshVoicePhrases();
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
