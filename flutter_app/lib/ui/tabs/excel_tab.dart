import 'package:flutter/material.dart';
import '../../models/app_settings.dart';
import '../../services/app_paths.dart';
import '../../services/modem_controller.dart';

class ExcelTab extends StatefulWidget {
  final ModemController controller;

  const ExcelTab({super.key, required this.controller});

  @override
  State<ExcelTab> createState() => _ExcelTabState();
}

class _ExcelTabState extends State<ExcelTab> {
  String? _selectedPresetName;
  String? _lastExportStatus;
  bool _rebuilding = false;

  ModemController get c => widget.controller;

  Future<void> _savePresetDialog() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохранить пресет колонок Excel'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название пресета',
            hintText: 'Например: Краткий отчёт по балансам',
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
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final copyCols = c.settings.excelColumns
        .map((e) => ExcelColumnSpec(key: e.key, header: e.header, enabled: e.enabled))
        .toList();
    c.settings.excelPresets.removeWhere((p) => p.name == name);
    c.settings.excelPresets.add(ExcelPreset(name: name, columns: copyCols));
    _selectedPresetName = name;
    await c.saveSettings();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Пресет «$name» сохранён.')),
      );
    }
  }

  Future<void> _applyPreset(String name) async {
    final found = c.settings.excelPresets.where((p) => p.name == name).toList();
    if (found.isEmpty) return;
    c.settings.excelColumns = found.first.columns
        .map((e) => ExcelColumnSpec(key: e.key, header: e.header, enabled: e.enabled))
        .toList();
    await c.saveSettings();
    if (mounted) setState(() {});
  }

  Future<void> _deleteSelectedPreset() async {
    if (_selectedPresetName == null) return;
    c.settings.excelPresets.removeWhere((p) => p.name == _selectedPresetName);
    _selectedPresetName = null;
    await c.saveSettings();
    if (mounted) setState(() {});
  }

  Future<void> _resetDefaults() async {
    c.settings.excelColumns = ExcelColumnSpec.defaults();
    await c.saveSettings();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Колонки Excel сброшены к стандартным.')),
      );
    }
  }

  Future<void> _rebuildExcel() async {
    setState(() => _rebuilding = true);
    try {
      await c.saveSettings();
      final res = await c.rebuildExcelNow();
      setState(() {
        _lastExportStatus = res.usedBackup
            ? 'Основной файл был занят в Excel — создана резервная копия (${res.rowCount} строк): ${res.savedPath}'
            : 'Файл Excel обновлён (${res.rowCount} строк): ${res.savedPath}';
      });
    } catch (e) {
      setState(() => _lastExportStatus = 'Ошибка экспорта Excel: $e');
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = c.settings.excelColumns;
    final presets = c.settings.excelPresets;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Левая панель: конструктор колонок и пресеты
          SizedBox(
            width: 410,
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
                          'Настройка колонок Excel (лист «Результаты»)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Файл: ${AppPaths.excelMainFile}',
                          style: const TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: presets.any((p) => p.name == _selectedPresetName)
                                    ? _selectedPresetName
                                    : null,
                                decoration: const InputDecoration(
                                  labelText: 'Пресеты колонок',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: presets
                                    .map((p) => DropdownMenuItem(
                                          value: p.name,
                                          child: Text(p.name),
                                        ))
                                    .toList(),
                                onChanged: (v) {
                                  setState(() => _selectedPresetName = v);
                                  if (v != null) _applyPreset(v);
                                },
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton.outlined(
                              tooltip: 'Сохранить пресет',
                              onPressed: _savePresetDialog,
                              icon: const Icon(Icons.bookmark_add_outlined, size: 19),
                            ),
                            IconButton.outlined(
                              tooltip: 'Удалить пресет',
                              onPressed:
                                  _selectedPresetName == null ? null : _deleteSelectedPreset,
                              icon: const Icon(Icons.delete_outline, size: 19),
                            ),
                            IconButton.outlined(
                              tooltip: 'Сбросить к стандарту',
                              onPressed: _resetDefaults,
                              icon: const Icon(Icons.restart_alt, size: 19),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      itemCount: cols.length,
                      onReorder: (oldIndex, newIndex) async {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = cols.removeAt(oldIndex);
                        cols.insert(newIndex, item);
                        await c.saveSettings();
                        setState(() {});
                      },
                      itemBuilder: (_, idx) {
                        final col = cols[idx];
                        return Container(
                          key: ValueKey(col.key),
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: col.enabled,
                                onChanged: (v) async {
                                  col.enabled = v ?? true;
                                  await c.saveSettings();
                                  setState(() {});
                                },
                              ),
                              Expanded(
                                child: TextFormField(
                                  key: ValueKey('${col.key}_${col.header}'),
                                  initialValue: col.header,
                                  decoration: InputDecoration(
                                    labelText: col.key,
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                  style: const TextStyle(fontSize: 13),
                                  onChanged: (v) => col.header = v,
                                ),
                              ),
                              const SizedBox(width: 28),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _rebuilding ? null : _rebuildExcel,
                        icon: const Icon(Icons.table_view),
                        label: Text(
                          _rebuilding
                              ? 'Формирование файла...'
                              : 'Пересобрать Excel из базы (${c.scenarioRuns.length})',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 14),

          // Правая панель: история запусков и сверка баланса
          Expanded(
            child: Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'История прогонов сценариев и сверка баланса',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                            ),
                            const Spacer(),
                            OutlinedButton.icon(
                              onPressed: () {
                                c.scenarioRuns = c.db.getScenarioRuns();
                                setState(() {});
                              },
                              icon: const Icon(Icons.refresh, size: 17),
                              label: const Text('Обновить'),
                            ),
                          ],
                        ),
                        if (_lastExportStatus != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0FDF4),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF86EFAC)),
                            ),
                            child: SelectableText(
                              _lastExportStatus!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: c.scenarioRuns.isEmpty
                        ? const Center(
                            child: Text(
                              'Запусков сценариев пока нет. Запустите сценарий во вкладке «Сценарии».',
                            ),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.vertical,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                headingRowHeight: 38,
                                dataRowMinHeight: 36,
                                dataRowMaxHeight: 54,
                                columns: const [
                                  DataColumn(label: Text('Дата')),
                                  DataColumn(label: Text('Сценарий')),
                                  DataColumn(label: Text('Оператор')),
                                  DataColumn(label: Text('Номер')),
                                  DataColumn(label: Text('1-й баланс')),
                                  DataColumn(label: Text('Посл. баланс')),
                                  DataColumn(label: Text('Разница')),
                                  DataColumn(label: Text('Сверка')),
                                  DataColumn(label: Text('Итог')),
                                ],
                                rows: c.scenarioRuns.map((r) {
                                  final isMatch = r.balanceMatchStatus == 'СОВПАЛ';
                                  final isMismatch = r.balanceMatchStatus == 'НЕ СОВПАЛ';
                                  return DataRow(cells: [
                                    DataCell(Text(r.startedAt, style: const TextStyle(fontSize: 12))),
                                    DataCell(Text(r.scenarioName, style: const TextStyle(fontSize: 12))),
                                    DataCell(Text(r.operatorName, style: const TextStyle(fontSize: 12))),
                                    DataCell(Text(r.phoneNumber, style: const TextStyle(fontSize: 12))),
                                    DataCell(Text(r.firstBalance?.toStringAsFixed(2) ?? '—')),
                                    DataCell(Text(r.lastBalance?.toStringAsFixed(2) ?? '—')),
                                    DataCell(Text(r.balanceDiff?.toStringAsFixed(2) ?? '—')),
                                    DataCell(
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: isMatch
                                              ? const Color(0xFFDCFCE7)
                                              : (isMismatch
                                                  ? const Color(0xFFFEE2E2)
                                                  : const Color(0xFFF1F5F9)),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          r.balanceMatchStatus,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: isMatch
                                                ? const Color(0xFF166534)
                                                : (isMismatch
                                                    ? const Color(0xFF991B1B)
                                                    : Colors.black54),
                                          ),
                                        ),
                                      ),
                                    ),
                                    DataCell(Text(r.status, style: const TextStyle(fontSize: 12))),
                                  ]);
                                }).toList(),
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
