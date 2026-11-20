import 'package:flutter/material.dart';
import '../../models/scenario_models.dart';
import '../../services/modem_controller.dart';

class ScenariosTab extends StatefulWidget {
  final ModemController controller;

  const ScenariosTab({super.key, required this.controller});

  @override
  State<ScenariosTab> createState() => _ScenariosTabState();
}

class _ScenariosTabState extends State<ScenariosTab> {
  String? _selectedId;
  ScenarioDefinition? _draft;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _opFilterCtrl = TextEditingController();

  ModemController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (c.scenarios.isNotEmpty) {
      _loadScenario(c.scenarios.first);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _opFilterCtrl.dispose();
    super.dispose();
  }

  void _loadScenario(ScenarioDefinition sc) {
    _selectedId = sc.id;
    _draft = sc.copyWith(steps: List<ScenarioStep>.from(sc.steps));
    _nameCtrl.text = sc.name;
    _opFilterCtrl.text = sc.operatorFilter;
  }

  void _createNewScenario() {
    final sc = ScenarioDefinition(
      id: 'sc_${DateTime.now().microsecondsSinceEpoch}',
      name: 'Новый сценарий ${c.scenarios.length + 1}',
      stopOnError: false,
      autoRunOnRegister: false,
      operatorFilter: '',
      steps: const [],
    );
    c.saveScenario(sc);
    setState(() => _loadScenario(sc));
  }

  void _duplicateCurrentScenario() {
    final d = _draft;
    if (d == null) return;
    final copy = d.copyWith(
      id: 'sc_${DateTime.now().microsecondsSinceEpoch}',
      name: '${d.name} (копия)',
      steps: d.steps
          .map((s) => s.copyWith(id: 'st_${DateTime.now().microsecondsSinceEpoch}_${s.id}'))
          .toList(),
    );
    c.saveScenario(copy);
    setState(() => _loadScenario(copy));
  }

  void _saveDraft() {
    final d = _draft;
    if (d == null) return;
    final updated = d.copyWith(
      name: _nameCtrl.text.trim().isEmpty ? 'Без названия' : _nameCtrl.text.trim(),
      operatorFilter: _opFilterCtrl.text.trim(),
    );
    c.saveScenario(updated);
    setState(() => _draft = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Сценарий «${updated.name}» сохранён.')),
    );
  }

  Future<void> _openStepEditor({ScenarioStep? existing, int? replaceIndex}) async {
    if (_draft == null) return;

    var type = existing?.type ?? ScenarioStepType.checkBalanceUssd;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final ussdCodeCtrl = TextEditingController(text: existing?.ussdCode ?? '*100#');
    var ussdDcs = existing?.ussdDcs ?? 15;
    var waitSms = existing?.waitSmsIfNoBalance ?? false;
    final smsTimeoutCtrl =
        TextEditingController(text: (existing?.smsWaitTimeoutSec ?? 30).toString());
    final smsSenderCtrl = TextEditingController(text: existing?.smsSenderFilter ?? '');
    final smsRecipCtrl = TextEditingController(text: existing?.smsRecipient ?? '');
    final smsBodyCtrl = TextEditingController(text: existing?.smsBody ?? '');
    var checkMinBal = existing?.checkMinBalance ?? false;
    final minBalCtrl =
        TextEditingController(text: (existing?.minBalanceThreshold ?? 10.0).toString());
    final pauseCtrl = TextEditingController(text: (existing?.pauseSec ?? 5).toString());
    final callNumCtrl = TextEditingController(text: existing?.callNumber ?? '');
    final callDurCtrl =
        TextEditingController(text: (existing?.callDurationSec ?? 20).toString());
    final callActions = List<CallSecondAction>.from(existing?.callActions ?? []);
    final dtmfCtrl = TextEditingController(text: existing?.dtmfDigits ?? '1');

    final actSecCtrl = TextEditingController(text: '5');
    var actKind = 'dtmf';
    final actValCtrl = TextEditingController(text: '1');

    final result = await showDialog<ScenarioStep>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlg) {
            return AlertDialog(
              title: Text(existing == null ? 'Добавить шаг' : 'Редактировать шаг'),
              content: SizedBox(
                width: 540,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<ScenarioStepType>(
                        value: type,
                        decoration: const InputDecoration(
                          labelText: 'Тип шага',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: ScenarioStepType.values
                            .map((t) => DropdownMenuItem(
                                  value: t,
                                  child: Text(t.label),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setDlg(() => type = v);
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Название шага (необязательно)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (type == ScenarioStepType.detectOwnNumberUssd ||
                          type == ScenarioStepType.customUssd ||
                          type == ScenarioStepType.checkBalanceUssd) ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: ussdCodeCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'USSD-команда',
                                  hintText: '*100#',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                value: ussdDcs,
                                decoration: const InputDecoration(
                                  labelText: 'DCS',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: const [
                                  DropdownMenuItem(value: 15, child: Text('15 (GSM-7)')),
                                  DropdownMenuItem(value: 72, child: Text('72 (UCS-2)')),
                                ],
                                onChanged: (v) {
                                  if (v != null) setDlg(() => ussdDcs = v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],

                      if (type == ScenarioStepType.checkBalanceUssd) ...[
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: waitSms,
                          onChanged: (v) => setDlg(() => waitSms = v ?? false),
                          title: const Text(
                            'Ждать входящее SMS, если сумма не пришла в USSD',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        if (waitSms)
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: smsTimeoutCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Таймаут SMS (сек)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: smsSenderCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Фильтр отправителя (необяз.)',
                                    hintText: 'MTS / MegaFon / 100',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],

                      if (type == ScenarioStepType.sendSms) ...[
                        TextField(
                          controller: smsRecipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Номер получателя',
                            hintText: '+79991234567',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: smsBodyCtrl,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Текст SMS',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: checkMinBal,
                          onChanged: (v) => setDlg(() => checkMinBal = v ?? false),
                          title: const Text(
                            'Проверять минимальный порог баланса перед отправкой',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        if (checkMinBal)
                          TextField(
                            controller: minBalCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Минимальный баланс (руб.)',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                      ],

                      if (type == ScenarioStepType.pause) ...[
                        TextField(
                          controller: pauseCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Длительность паузы (сек)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ],

                      if (type == ScenarioStepType.voiceCall) ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: callNumCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Номер для звонка',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: callDurCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Длительность (с)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Действия по секундам во время разговора:',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            SizedBox(
                              width: 72,
                              child: TextField(
                                controller: actSecCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Сек',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 130,
                              child: DropdownButtonFormField<String>(
                                value: actKind,
                                decoration: const InputDecoration(
                                  labelText: 'Действие',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: const [
                                  DropdownMenuItem(value: 'dtmf', child: Text('DTMF')),
                                  DropdownMenuItem(value: 'phrase', child: Text('Фраза WAV')),
                                ],
                                onChanged: (v) {
                                  if (v != null) setDlg(() => actKind = v);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: actKind == 'phrase' && c.voicePhrases.isNotEmpty
                                  ? DropdownButtonFormField<String>(
                                      value: c.voicePhrases.any((p) => p.name == actValCtrl.text)
                                          ? actValCtrl.text
                                          : c.voicePhrases.first.name,
                                      decoration: const InputDecoration(
                                        labelText: 'Файл фразы',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                      items: c.voicePhrases
                                          .map((p) => DropdownMenuItem(
                                                value: p.name,
                                                child: Text(p.name,
                                                    overflow: TextOverflow.ellipsis),
                                              ))
                                          .toList(),
                                      onChanged: (v) {
                                        if (v != null) actValCtrl.text = v;
                                      },
                                    )
                                  : TextField(
                                      controller: actValCtrl,
                                      decoration: InputDecoration(
                                        labelText: actKind == 'phrase'
                                            ? 'Имя WAV из Sounds'
                                            : 'Цифры DTMF',
                                        border: const OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 6),
                            IconButton.filledTonal(
                              onPressed: () {
                                final sec = int.tryParse(actSecCtrl.text) ?? 5;
                                final val = actKind == 'phrase' &&
                                        actValCtrl.text.isEmpty &&
                                        c.voicePhrases.isNotEmpty
                                    ? c.voicePhrases.first.name
                                    : actValCtrl.text.trim();
                                if (val.isEmpty) return;
                                setDlg(() {
                                  callActions.add(CallSecondAction(
                                    atSecond: sec,
                                    kind: actKind,
                                    value: val,
                                  ));
                                  callActions.sort((a, b) => a.atSecond.compareTo(b.atSecond));
                                });
                              },
                              icon: const Icon(Icons.add),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (callActions.isNotEmpty)
                          ...callActions.asMap().entries.map((e) {
                            final act = e.value;
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                radius: 14,
                                child: Text('${act.atSecond}с',
                                    style: const TextStyle(fontSize: 10)),
                              ),
                              title: Text(
                                act.kind == 'phrase'
                                    ? 'Фраза: ${act.value}'
                                    : 'DTMF: ${act.value}',
                                style: const TextStyle(fontSize: 13),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => setDlg(() => callActions.removeAt(e.key)),
                              ),
                            );
                          }),
                      ],

                      if (type == ScenarioStepType.sendDtmf) ...[
                        TextField(
                          controller: dtmfCtrl,
                          decoration: const InputDecoration(
                            labelText: 'DTMF-цифры (0-9, *, #)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    final step = ScenarioStep(
                      id: existing?.id ??
                          'st_${DateTime.now().microsecondsSinceEpoch}',
                      type: type,
                      title: titleCtrl.text.trim(),
                      ussdCode: ussdCodeCtrl.text.trim().isEmpty
                          ? '*100#'
                          : ussdCodeCtrl.text.trim(),
                      ussdDcs: ussdDcs,
                      waitSmsIfNoBalance: waitSms,
                      smsWaitTimeoutSec: int.tryParse(smsTimeoutCtrl.text) ?? 30,
                      smsSenderFilter: smsSenderCtrl.text.trim(),
                      smsRecipient: smsRecipCtrl.text.trim(),
                      smsBody: smsBodyCtrl.text,
                      checkMinBalance: checkMinBal,
                      minBalanceThreshold:
                          double.tryParse(minBalCtrl.text.replaceAll(',', '.')) ??
                              10.0,
                      pauseSec: int.tryParse(pauseCtrl.text) ?? 5,
                      callNumber: callNumCtrl.text.trim(),
                      callDurationSec: int.tryParse(callDurCtrl.text) ?? 20,
                      callActions: callActions,
                      dtmfDigits: dtmfCtrl.text.trim(),
                    );
                    Navigator.pop(ctx, step);
                  },
                  child: const Text('Сохранить шаг'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null && _draft != null) {
      final list = List<ScenarioStep>.from(_draft!.steps);
      if (replaceIndex != null && replaceIndex >= 0 && replaceIndex < list.length) {
        list[replaceIndex] = result;
      } else {
        list.add(result);
      }
      setState(() => _draft = _draft!.copyWith(steps: list));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_draft == null && c.scenarios.isNotEmpty) {
      _loadScenario(c.scenarios.first);
    }

    final running = c.scenarioEngine.isRunning;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Левая колонка: список сценариев
          SizedBox(
            width: 280,
            child: Card(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Text(
                          'Сценарии',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        FilledButton.tonalIcon(
                          onPressed: _createNewScenario,
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('Новый'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: c.scenarios.length,
                      itemBuilder: (_, idx) {
                        final sc = c.scenarios[idx];
                        final selected = sc.id == _selectedId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          selectedTileColor: const Color(0xFFE2E8F0),
                          title: Text(
                            sc.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            'Шагов: ${sc.steps.length}${sc.autoRunOnRegister ? ' · Автозапуск' : ''}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            tooltip: 'Удалить сценарий',
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () {
                              c.deleteScenario(sc.id);
                              setState(() {
                                if (_selectedId == sc.id) {
                                  _selectedId = null;
                                  _draft = c.scenarios.isNotEmpty
                                      ? c.scenarios.first
                                      : null;
                                  if (_draft != null) _loadScenario(_draft!);
                                }
                              });
                            },
                          ),
                          onTap: () => setState(() => _loadScenario(sc)),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 14),

          // Центральная колонка: редактор шагов
          Expanded(
            flex: 3,
            child: Card(
              child: _draft == null
                  ? const Center(
                      child: Text('Создайте сценарий или выберите из списка слева.'),
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _nameCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Название сценария',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  OutlinedButton.icon(
                                    onPressed: _duplicateCurrentScenario,
                                    icon: const Icon(Icons.copy, size: 16),
                                    label: const Text('Дублировать'),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.icon(
                                    onPressed: _saveDraft,
                                    icon: const Icon(Icons.save, size: 16),
                                    label: const Text('Сохранить'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: CheckboxListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      value: _draft!.stopOnError,
                                      onChanged: (v) => setState(() {
                                        _draft = _draft!
                                            .copyWith(stopOnError: v ?? false);
                                      }),
                                      title: const Text('Останавливать при ошибке',
                                          style: TextStyle(fontSize: 12)),
                                    ),
                                  ),
                                  Expanded(
                                    child: CheckboxListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      value: _draft!.autoRunOnRegister,
                                      onChanged: (v) => setState(() {
                                        _draft = _draft!.copyWith(
                                            autoRunOnRegister: v ?? false);
                                      }),
                                      title: const Text(
                                          'Автозапуск при регистрации в сети',
                                          style: TextStyle(fontSize: 12)),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 190,
                                    child: TextField(
                                      controller: _opFilterCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Фильтр оператора',
                                        hintText: 'MTS / Beeline',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: Row(
                            children: [
                              Text(
                                'Шаги (${_draft!.steps.length}) — перетаскивайте для изменения порядка',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54),
                              ),
                              const Spacer(),
                              FilledButton.tonalIcon(
                                onPressed: () => _openStepEditor(),
                                icon: const Icon(Icons.add, size: 17),
                                label: const Text('Добавить шаг'),
                              ),
                              const SizedBox(width: 8),
                              if (!running)
                                FilledButton.icon(
                                  onPressed: c.snapshot.connected &&
                                          !c.snapshot.simMissing &&
                                          _draft!.steps.isNotEmpty
                                      ? () async {
                                          _saveDraft();
                                          await c.executeScenario(_draft!);
                                        }
                                      : null,
                                  icon: const Icon(Icons.play_arrow, size: 18),
                                  label: const Text('Запустить'),
                                )
                              else
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFDC2626)),
                                  onPressed: () =>
                                      c.scenarioEngine.requestCancel(),
                                  icon: const Icon(Icons.stop, size: 18),
                                  label: const Text('Остановить'),
                                ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: _draft!.steps.isEmpty
                              ? const Center(
                                  child: Text(
                                      'Добавьте шаги кнопкой «Добавить шаг» выше.'),
                                )
                              : ReorderableListView.builder(
                                  padding: const EdgeInsets.all(10),
                                  itemCount: _draft!.steps.length,
                                  onReorder: (oldIndex, newIndex) {
                                    setState(() {
                                      if (newIndex > oldIndex) newIndex -= 1;
                                      final list =
                                          List<ScenarioStep>.from(_draft!.steps);
                                      final item = list.removeAt(oldIndex);
                                      list.insert(newIndex, item);
                                      _draft = _draft!.copyWith(steps: list);
                                    });
                                  },
                                  itemBuilder: (_, idx) {
                                    final st = _draft!.steps[idx];
                                    return Card(
                                      key: ValueKey(st.id),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      color: const Color(0xFFF8FAFC),
                                      child: ListTile(
                                        leading: CircleAvatar(
                                          radius: 14,
                                          backgroundColor: const Color(0xFF0F172A),
                                          foregroundColor: Colors.white,
                                          child: Text('${idx + 1}',
                                              style: const TextStyle(fontSize: 12)),
                                        ),
                                        title: Text(
                                          st.title.isNotEmpty
                                              ? '${st.title} (${st.type.label})'
                                              : st.type.label,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        subtitle: Text(
                                          st.summary,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              tooltip: 'Редактировать',
                                              icon: const Icon(Icons.edit_outlined,
                                                  size: 18),
                                              onPressed: () => _openStepEditor(
                                                existing: st,
                                                replaceIndex: idx,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: 'Дублировать шаг',
                                              icon: const Icon(Icons.copy_outlined,
                                                  size: 18),
                                              onPressed: () {
                                                final list =
                                                    List<ScenarioStep>.from(
                                                        _draft!.steps);
                                                list.insert(
                                                  idx + 1,
                                                  st.copyWith(
                                                    id: 'st_${DateTime.now().microsecondsSinceEpoch}',
                                                  ),
                                                );
                                                setState(() => _draft =
                                                    _draft!.copyWith(steps: list));
                                              },
                                            ),
                                            IconButton(
                                              tooltip: 'Удалить шаг',
                                              icon: const Icon(Icons.delete_outline,
                                                  size: 18),
                                              onPressed: () {
                                                final list =
                                                    List<ScenarioStep>.from(
                                                        _draft!.steps)
                                                      ..removeAt(idx);
                                                setState(() => _draft =
                                                    _draft!.copyWith(steps: list));
                                              },
                                            ),
                                            const SizedBox(width: 22),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
            ),
          ),

          const SizedBox(width: 14),

          // Правая колонка: живой лог выполнения
          SizedBox(
            width: 310,
            child: Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Text(
                          'Ход выполнения',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        if (running)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: c.scenarioProgressLog.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                'Запустите сценарий — здесь появятся пошаговые ответы USSD, сверка баланса и статус записи Excel.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(10),
                            itemCount: c.scenarioProgressLog.length,
                            itemBuilder: (_, i) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: SelectableText(
                                c.scenarioProgressLog[i],
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
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
