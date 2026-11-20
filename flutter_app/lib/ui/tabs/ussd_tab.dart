import 'package:flutter/material.dart';
import '../../models/app_settings.dart';
import '../../services/modem_controller.dart';

class UssdTab extends StatefulWidget {
  final ModemController controller;

  const UssdTab({super.key, required this.controller});

  @override
  State<UssdTab> createState() => _UssdTabState();
}

class _UssdTabState extends State<UssdTab> {
  final TextEditingController _codeCtrl = TextEditingController(text: '*100#');
  final TextEditingController _newLabelCtrl = TextEditingController();
  final TextEditingController _newCodeCtrl = TextEditingController();
  final TextEditingController _pauseSecCtrl = TextEditingController(text: '3');
  final TextEditingController _repeatsCtrl = TextEditingController(text: '1');

  int _dcs = 15;
  bool _sending = false;
  bool _batchRunning = false;
  bool _batchStopRequested = false;
  String _output = '';
  final Set<String> _batchSelectedIds = {};

  ModemController get c => widget.controller;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _newLabelCtrl.dispose();
    _newCodeCtrl.dispose();
    _pauseSecCtrl.dispose();
    _repeatsCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendSingle(String code, {int? dcs}) async {
    if (!c.snapshot.connected || c.snapshot.simMissing) return;
    final useDcs = dcs ?? _dcs;
    setState(() {
      _sending = true;
      _output = 'Отправка $code (DCS=$useDcs)...';
    });
    try {
      final res = await c.modem.sendUssd(code, dcs: useDcs);
      c.db.logOperation('USSD', '$code (DCS=$useDcs)', 'Ответ', res);
      if (mounted) setState(() => _output = res);
    } catch (e) {
      if (mounted) setState(() => _output = 'Ошибка USSD: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _runBatch() async {
    if (!c.snapshot.connected || c.snapshot.simMissing) return;
    final selected = c.settings.savedUssd
        .where((u) => _batchSelectedIds.contains(u.id))
        .toList();
    if (selected.isEmpty) return;

    final pauseSec = (int.tryParse(_pauseSecCtrl.text) ?? 3).clamp(0, 120);
    final repeats = (int.tryParse(_repeatsCtrl.text) ?? 1).clamp(1, 50);

    setState(() {
      _batchRunning = true;
      _batchStopRequested = false;
      _output = 'Старт пакетного USSD: ${selected.length} команд × $repeats повт.\n';
    });

    try {
      for (var r = 1; r <= repeats; r++) {
        if (_batchStopRequested) break;
        for (final item in selected) {
          if (_batchStopRequested) break;
          setState(() {
            _output += '\n[Повт. $r/$repeats] ${item.label} (${item.code}, DCS=${item.dcs})...\n';
          });
          final reply = await c.modem.sendUssd(item.code, dcs: item.dcs);
          c.db.logOperation('Пакетный USSD', item.code, 'Ответ', reply);
          if (!mounted) return;
          setState(() => _output += '→ $reply\n');
          if (pauseSec > 0 && !_batchStopRequested) {
            await Future.delayed(Duration(seconds: pauseSec));
          }
        }
      }
      if (mounted) {
        setState(() {
          _output += _batchStopRequested
              ? '\n[Пакетный запуск остановлен пользователем]'
              : '\n[Пакетный запуск завершён]';
        });
      }
    } finally {
      if (mounted) setState(() => _batchRunning = false);
    }
  }

  Future<void> _addSavedUssd() async {
    final label = _newLabelCtrl.text.trim();
    final code = _newCodeCtrl.text.trim();
    if (code.isEmpty) return;
    c.settings.savedUssd.add(SavedUssdCommand(
      id: 'u_${DateTime.now().microsecondsSinceEpoch}',
      label: label.isEmpty ? code : label,
      code: code,
      dcs: _dcs,
    ));
    _newLabelCtrl.clear();
    _newCodeCtrl.clear();
    await c.saveSettings();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connected = c.snapshot.connected && !c.snapshot.simMissing;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Левая часть: ручной запрос + вывод
          Expanded(
            flex: 3,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ручной USSD-запрос (Huawei E173 · DCS 15 / 72)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _codeCtrl,
                            decoration: const InputDecoration(
                              labelText: 'USSD-команда или пункт меню',
                              hintText: '*100#',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _sendSingle(_codeCtrl.text),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 165,
                          child: DropdownButtonFormField<int>(
                            value: _dcs,
                            decoration: const InputDecoration(
                              labelText: 'Кодировка DCS',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(value: 15, child: Text('15 (GSM-7 PDU)')),
                              DropdownMenuItem(value: 72, child: Text('72 (UCS-2)')),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _dcs = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: connected && !_sending && !_batchRunning
                              ? () => _sendSingle(_codeCtrl.text)
                              : null,
                          icon: const Icon(Icons.send, size: 17),
                          label: const Text('Отправить'),
                        ),
                        const SizedBox(width: 6),
                        OutlinedButton(
                          onPressed: connected
                              ? () async {
                                  await c.modem.cancelUssdSession();
                                  setState(() => _output = 'Сессия USSD закрыта (AT+CUSD=2).');
                                }
                              : null,
                          child: const Text('Закрыть сессию'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Если «no network service»:',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        OutlinedButton(
                          onPressed: connected
                              ? () async {
                                  await c.modem.enableNetworkForUssd(only2g: false);
                                  setState(() => _output =
                                      'Включён режим Авто 2G/3G (CS+PS). Подождите 5–10 сек регистрации и повторите USSD.');
                                }
                              : null,
                          child: const Text('Авто 2G/3G (CS+PS)'),
                        ),
                        OutlinedButton(
                          onPressed: connected
                              ? () async {
                                  await c.modem.enableNetworkForUssd(only2g: true);
                                  setState(() => _output =
                                      'Включён режим Только 2G GSM (CS+PS). Подождите 5–10 сек регистрации и повторите USSD.');
                                }
                              : null,
                          child: const Text('Только 2G GSM'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Ответ оператора:',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            _output.isEmpty
                                ? 'Введите USSD-команду (например *100#) и нажмите «Отправить».'
                                : _output,
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 13,
                              color: Color(0xFFE2E8F0),
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(width: 14),

          // Правая часть: сохранённые команды + пакетный запуск
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
                          'Сохранённые USSD и пакетный запуск',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _newLabelCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Название',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 105,
                              child: TextField(
                                controller: _newCodeCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Код',
                                  hintText: '*100#',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton.filledTonal(
                              tooltip: 'Сохранить команду',
                              onPressed: _addSavedUssd,
                              icon: const Icon(Icons.add),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: c.settings.savedUssd.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, idx) {
                        final item = c.settings.savedUssd[idx];
                        final checked = _batchSelectedIds.contains(item.id);
                        return ListTile(
                          dense: true,
                          leading: Checkbox(
                            value: checked,
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _batchSelectedIds.add(item.id);
                                } else {
                                  _batchSelectedIds.remove(item.id);
                                }
                              });
                            },
                          ),
                          title: Text(item.label,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          subtitle: Text('${item.code} · DCS ${item.dcs}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Выполнить сейчас',
                                icon: const Icon(Icons.play_arrow, size: 19),
                                onPressed: connected && !_sending && !_batchRunning
                                    ? () {
                                        _codeCtrl.text = item.code;
                                        _sendSingle(item.code, dcs: item.dcs);
                                      }
                                    : null,
                              ),
                              IconButton(
                                tooltip: 'Удалить',
                                icon: const Icon(Icons.delete_outline, size: 18),
                                onPressed: () async {
                                  _batchSelectedIds.remove(item.id);
                                  c.settings.savedUssd.removeAt(idx);
                                  await c.saveSettings();
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _pauseSecCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Пауза (сек)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _repeatsCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Повторов',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: !_batchRunning
                              ? FilledButton.icon(
                                  onPressed: connected && _batchSelectedIds.isNotEmpty
                                      ? _runBatch
                                      : null,
                                  icon: const Icon(Icons.playlist_play),
                                  label: Text(
                                    'Пакетный запуск (${_batchSelectedIds.length})',
                                  ),
                                )
                              : FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFDC2626),
                                  ),
                                  onPressed: () =>
                                      setState(() => _batchStopRequested = true),
                                  icon: const Icon(Icons.stop),
                                  label: const Text('Остановить пакет'),
                                ),
                        ),
                      ],
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
