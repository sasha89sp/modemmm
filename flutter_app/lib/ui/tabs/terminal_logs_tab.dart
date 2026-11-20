import 'package:flutter/material.dart';
import '../../models/modem_models.dart';
import '../../services/modem_controller.dart';

class TerminalLogsTab extends StatefulWidget {
  final ModemController controller;

  const TerminalLogsTab({super.key, required this.controller});

  @override
  State<TerminalLogsTab> createState() => _TerminalLogsTabState();
}

class _TerminalLogsTabState extends State<TerminalLogsTab> {
  final TextEditingController _atCtrl = TextEditingController(text: 'ATI');
  String _sysLevelFilter = '';
  String? _csvExportNote;

  List<OperationLogEntry> _cachedOps = const [];
  int _cachedOpsVersion = -1;
  List<SystemLogEntry> _cachedSysLogs = const [];
  int _cachedSysVersion = -1;
  String _cachedSysFilter = '__init__';

  ModemController get c => widget.controller;

  @override
  void dispose() {
    _atCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendAt(String cmd) async {
    final clean = cmd.trim();
    if (clean.isEmpty || !c.snapshot.connected) return;
    await c.sendManualAtCommand(clean);
    if (mounted) setState(() {});
  }

  Future<void> _exportCsv() async {
    final path = await c.db.exportOperationsToCsv();
    if (mounted) {
      setState(() => _csvExportNote = 'Журнал экспортирован в CSV: $path');
    }
  }

  List<OperationLogEntry> _getOpsCached({bool force = false}) {
    if (!c.initialized) return const [];
    if (force || _cachedOpsVersion != c.logsDataVersion) {
      _cachedOpsVersion = c.logsDataVersion;
      _cachedOps = c.db.getOperationLogs(limit: 500);
    }
    return _cachedOps;
  }

  List<SystemLogEntry> _getSysLogsCached({bool force = false}) {
    if (!c.initialized) return const [];
    if (force ||
        _cachedSysVersion != c.logsDataVersion ||
        _cachedSysFilter != _sysLevelFilter) {
      _cachedSysVersion = c.logsDataVersion;
      _cachedSysFilter = _sysLevelFilter;
      _cachedSysLogs = c.db.getSystemLogs(
        limit: 500,
        level: _sysLevelFilter.isEmpty ? null : _sysLevelFilter,
      );
    }
    return _cachedSysLogs;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Column(
            children: [
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(icon: Icon(Icons.terminal, size: 17), text: 'AT-терминал'),
                  Tab(icon: Icon(Icons.history, size: 17), text: 'История операций (SQLite)'),
                  Tab(icon: Icon(Icons.list_alt, size: 17), text: 'Системный журнал'),
                  Tab(icon: Icon(Icons.speed, size: 17), text: 'Диагностика DIAG'),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildAtTerminal(),
                    _buildOperationsTab(),
                    _buildSystemLogTab(),
                    _buildDiagTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAtTerminal() {
    const quick = [
      'ATI',
      'AT+CPIN?',
      'AT+CSQ',
      'AT+CREG?',
      'AT+COPS?',
      'AT^SYSINFO',
      'AT+CNMI?',
      'AT+CPMS?',
      'AT^CARDLOCK?',
    ];

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _atCtrl,
                  decoration: const InputDecoration(
                    labelText: 'AT-команда напрямую в модем',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: _sendAt,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: c.snapshot.connected ? () => _sendAt(_atCtrl.text) : null,
                icon: const Icon(Icons.send, size: 17),
                label: const Text('Отправить'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  c.liveAtLines.clear();
                  setState(() {});
                },
                child: const Text('Очистить экран'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: quick
                .map((cmd) => ActionChip(
                      label: Text(cmd, style: const TextStyle(fontSize: 11.5)),
                      onPressed: c.snapshot.connected
                          ? () {
                              _atCtrl.text = cmd;
                              _sendAt(cmd);
                            }
                          : null,
                    ))
                .toList(),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListView.builder(
                itemCount: c.liveAtLines.length,
                itemBuilder: (_, i) {
                  final line = c.liveAtLines[i];
                  final isTx = line.contains(' TX ');
                  return SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                      color: isTx
                          ? const Color(0xFF38BDF8)
                          : const Color(0xFFCBD5E1),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOperationsTab() {
    final List<OperationLogEntry> ops = _getOpsCached();

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Записей в истории: ${ops.length}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () {
                  _getOpsCached(force: true);
                  setState(() {});
                },
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Обновить'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: c.initialized ? _exportCsv : null,
                icon: const Icon(Icons.download, size: 17),
                label: const Text('Экспорт в CSV'),
              ),
            ],
          ),
          if (_csvExportNote != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              _csvExportNote!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF166534)),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              border: Border(bottom: BorderSide(color: Color(0xFFCBD5E1))),
            ),
            child: const Row(
              children: [
                SizedBox(
                  width: 145,
                  child: Text('Дата',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                SizedBox(
                  width: 125,
                  child: Text('Категория',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                SizedBox(
                  width: 210,
                  child: Text('Действие',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                SizedBox(
                  width: 120,
                  child: Text('Результат',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Text('Детали',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ops.isEmpty
                ? const Center(child: Text('История операций пока пуста.'))
                : ListView.separated(
                    itemCount: ops.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, idx) {
                      final o = ops[idx];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 145,
                              child: Text(o.createdAt,
                                  style: const TextStyle(
                                      fontFamily: 'Consolas',
                                      fontSize: 11.5,
                                      color: Colors.black54)),
                            ),
                            SizedBox(
                              width: 125,
                              child: Text(o.category,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                            ),
                            SizedBox(
                              width: 210,
                              child: Text(o.action,
                                  style: const TextStyle(fontSize: 12)),
                            ),
                            SizedBox(
                              width: 120,
                              child: Text(o.result,
                                  style: const TextStyle(fontSize: 12)),
                            ),
                            Expanded(
                              child: Text(
                                o.details,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemLogTab() {
    final List<SystemLogEntry> logs = _getSysLogsCached();

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              const Text('Фильтр уровня: '),
              const SizedBox(width: 8),
              SizedBox(
                width: 160,
                child: DropdownButtonFormField<String>(
                  value: _sysLevelFilter,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('Все события')),
                    DropdownMenuItem(value: 'TX', child: Text('TX (исх. AT)')),
                    DropdownMenuItem(value: 'RX', child: Text('RX (ответы)')),
                    DropdownMenuItem(value: 'INFO', child: Text('INFO')),
                    DropdownMenuItem(value: 'WARN', child: Text('WARN')),
                    DropdownMenuItem(value: 'ERR', child: Text('ERR')),
                    DropdownMenuItem(value: 'DIAG', child: Text('DIAG')),
                  ],
                  onChanged: (v) => setState(() => _sysLevelFilter = v ?? ''),
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () {
                  _getSysLogsCached(force: true);
                  setState(() {});
                },
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Обновить'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  c.db.clearSystemLogs();
                  _getSysLogsCached(force: true);
                  setState(() {});
                },
                icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                label: const Text('Очистить лог'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.separated(
              itemCount: logs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, idx) {
                final l = logs[idx];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 145,
                        child: Text(
                          l.createdAt,
                          style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11.5,
                              color: Colors.black54),
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          l.level,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: l.level == 'ERR'
                                ? const Color(0xFFDC2626)
                                : (l.level == 'WARN'
                                    ? const Color(0xFFD97706)
                                    : const Color(0xFF0F172A)),
                          ),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          l.message,
                          style: const TextStyle(
                              fontFamily: 'Consolas', fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagTab() {
    final metrics = c.diagMetrics;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'DIAG — длительность и интервалы фоновых циклов',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => setState(() {}),
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Обновить метрики'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DataTable(
            columns: const [
              DataColumn(label: Text('Фоновый цикл')),
              DataColumn(label: Text('Посл. (мс)')),
              DataColumn(label: Text('Средн. (мс)')),
              DataColumn(label: Text('Макс. (мс)')),
              DataColumn(label: Text('Выполнений')),
              DataColumn(label: Text('Интервал')),
              DataColumn(label: Text('Текущее состояние')),
            ],
            rows: metrics
                .map((m) => DataRow(cells: [
                      DataCell(Text(m.loopName,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                      DataCell(Text('${m.lastDurationMs}')),
                      DataCell(Text(m.avgDurationMs.toStringAsFixed(1))),
                      DataCell(Text('${m.maxDurationMs}')),
                      DataCell(Text('${m.executions}')),
                      DataCell(Text('${m.currentIntervalSec}с')),
                      DataCell(Text(m.stateNote)),
                    ]))
                .toList(),
          ),
        ],
      ),
    );
  }
}
