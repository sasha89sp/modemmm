import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/debug_profiler_service.dart';
import '../../services/modem_controller.dart';

class DebugProfilerTab extends StatefulWidget {
  final ModemController controller;

  const DebugProfilerTab({super.key, required this.controller});

  @override
  State<DebugProfilerTab> createState() => _DebugProfilerTabState();
}

class _DebugProfilerTabState extends State<DebugProfilerTab> {
  String _eventFilter = 'ALL'; // ALL, PROBLEMS, PERF, MODEM, SQL, VOICE, UI
  final TextEditingController _searchCtrl = TextEditingController();
  String? _exportNote;

  ModemController get c => widget.controller;
  DebugProfilerService get p => widget.controller.profiler;

  @override
  void initState() {
    super.initState();
    p.addListener(_onProfilerTick);
  }

  @override
  void dispose() {
    p.removeListener(_onProfilerTick);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onProfilerTick() {
    if (mounted) setState(() {});
  }

  String _modemSummary() {
    final s = c.snapshot;
    return s.connected
        ? '${s.port} (${s.model}) · ${s.simStatus} · ${s.operatorName} · ${s.signalPercent}% · интервал ${c.currentStatusIntervalSec}с'
        : 'Не подключён';
  }

  String _voiceSummary() {
    return 'bridge=${c.voice.isBridgeActive}, port=${c.settings.preferredVoicePort}, TX=${c.voice.txBytes}B, RX=${c.voice.rxBytes}B, cap=${c.voiceCapabilityStatus}';
  }

  Future<void> _copyReport() async {
    final text = p.buildTextReport(
      modemSummary: _modemSummary(),
      voiceSummary: _voiceSummary(),
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Полный отчёт отладки скопирован в буфер обмена.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _exportReport() async {
    final path = await p.exportReportToFile(
      modemSummary: _modemSummary(),
      voiceSummary: _voiceSummary(),
    );
    if (mounted) {
      setState(() => _exportNote = 'Отчёт сохранён: $path');
    }
  }

  List<DebugEventEntry> _filteredEvents() {
    final query = _searchCtrl.text.trim().toLowerCase();
    return p.events.where((ev) {
      if (_eventFilter == 'PROBLEMS' &&
          ev.level != 'PERF' &&
          ev.level != 'WARN' &&
          ev.level != 'ERR') {
        return false;
      }
      if (_eventFilter == 'PERF' && ev.level != 'PERF') return false;
      if (_eventFilter == 'MODEM' && ev.category != 'MODEM') return false;
      if (_eventFilter == 'SQL' && ev.category != 'SQL') return false;
      if (_eventFilter == 'VOICE' && ev.category != 'VOICE') return false;
      if (_eventFilter == 'UI' && ev.category != 'UI') return false;
      if (query.isNotEmpty) {
        final hay = '${ev.level} ${ev.category} ${ev.subsystem} ${ev.message}'
            .toLowerCase();
        if (!hay.contains(query)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = p.enabled;
    final res = p.resources;
    final problems = p.detectProblems();
    final subsystems = p.sortedSubsystems;
    final totalMs = p.totalTrackedMs;
    final filteredEvents = _filteredEvents();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Верхняя панель включения / выключения отладки
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    enabled ? Icons.bug_report : Icons.bug_report_outlined,
                    size: 24,
                    color: enabled
                        ? const Color(0xFF15803D)
                        : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Полная отладка и профилировщик процессов',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: enabled
                                    ? const Color(0xFFDCFCE7)
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                enabled
                                    ? 'АКТИВНА (в реальном времени · PID ${res.pid})'
                                    : 'ОТКЛЮЧЕНА (нагрузка 0%)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: enabled
                                      ? const Color(0xFF166534)
                                      : const Color(0xFF475569),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          enabled
                              ? 'Сбор CPU/RAM/Handles Windows, кадров UI, перерисовок, COM/AT, SQLite и аудиомоста каждую секунду.'
                              : 'Профилировщик полностью остановлен: таймеры, Win32-опрос и FrameTimings отключены и не тратят ресурсы.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    onChanged: (v) => c.setDebugProfilerEnabled(v),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: enabled ? p.resetStats : null,
                    icon: const Icon(Icons.restart_alt, size: 17),
                    label: const Text('Сбросить'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _copyReport,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Копировать отчёт'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _exportReport,
                    icon: const Icon(Icons.save_alt, size: 17),
                    label: const Text('Сохранить TXT'),
                  ),
                ],
              ),
            ),
          ),

          if (_exportNote != null) ...[
            const SizedBox(height: 6),
            SelectableText(
              _exportNote!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF166534)),
            ),
          ],

          const SizedBox(height: 10),

          if (!enabled)
            Expanded(
              child: Card(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.speed_outlined,
                            size: 48,
                            color: Color(0xFF94A3B8),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Режим подробной отладки сейчас выключен',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Включите переключатель выше, когда нужно в реальном времени увидеть загрузку CPU и RAM процесса, число Win32 Handles, фризы кадров Flutter, штормы перерисовок и точное время каждой подсистемы (COM/AT, USB Hotplug, PowerShell PnP, SQLite, PDU SMS, аудиомост winmm.dll).',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: () => c.setDebugProfilerEnabled(true),
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('Включить полную отладку'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                children: [
                  // 1. Карточки системных ресурсов процесса Windows
                  Row(
                    children: [
                      Expanded(
                        child: _metricCard(
                          title: 'Процессор (CPU)',
                          primary: '${res.cpuTotalPercent.toStringAsFixed(1)}%',
                          secondary:
                              'User ${res.cpuUserPercent.toStringAsFixed(1)}% · Kernel ${res.cpuKernelPercent.toStringAsFixed(1)}% · Пик ${res.peakCpuPercent.toStringAsFixed(1)}%',
                          accent: res.cpuTotalPercent >= 15
                              ? const Color(0xFFDC2626)
                              : (res.cpuTotalPercent >= 6
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF15803D)),
                          icon: Icons.memory,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _metricCard(
                          title: 'Память (RAM)',
                          primary: '${res.workingSetMb.toStringAsFixed(1)} МБ',
                          secondary:
                              'Private ${res.privateMb.toStringAsFixed(1)} МБ · Пик ${res.peakWorkingSetMb.toStringAsFixed(1)} МБ',
                          accent: const Color(0xFF1D4ED8),
                          icon: Icons.sd_storage_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _metricCard(
                          title: 'Дескрипторы Win32',
                          primary: '${res.handleCount}',
                          secondary:
                              'GDI: ${res.gdiObjects} · USER: ${res.userObjects} · Ядер: ${res.logicalCores}',
                          accent: const Color(0xFF0F172A),
                          icon: Icons.hub_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _metricCard(
                          title: 'Кадры и UI Flutter',
                          primary: '${res.fps.toStringAsFixed(0)} FPS',
                          secondary:
                              'Build ${res.avgBuildMs.toStringAsFixed(1)}/${res.maxBuildMs.toStringAsFixed(0)}мс · Фризы: ${res.severeFreezeFrames} · Notify: ${res.uiNotifiesPerSec}/с',
                          accent: res.severeFreezeFrames > 0
                              ? const Color(0xFFDC2626)
                              : const Color(0xFF0369A1),
                          icon: Icons.monitor_heart_outlined,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // 2. Автоматический анализатор проблем
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                problems.isEmpty
                                    ? Icons.verified_outlined
                                    : Icons.warning_amber_rounded,
                                size: 19,
                                color: problems.isEmpty
                                    ? const Color(0xFF15803D)
                                    : const Color(0xFFD97706),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                problems.isEmpty
                                    ? 'Анализ узких мест: проблем не обнаружено'
                                    : 'Обнаруженные проблемы и узкие места (${problems.length})',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Аптайм отладки: ${res.uptime.inSeconds} сек · Всего notify: ${res.totalUiNotifies}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                          if (problems.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            ...problems.map((iss) {
                              final isHigh = iss.severity == 'HIGH';
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: isHigh
                                      ? const Color(0xFFFEF2F2)
                                      : const Color(0xFFFFFBEB),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isHigh
                                        ? const Color(0xFFFCA5A5)
                                        : const Color(0xFFFCD34D),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isHigh ? '[КРИТ]' : '[ВНИМ]',
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: isHigh
                                            ? const Color(0xFFDC2626)
                                            : const Color(0xFFB45309),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${iss.title} — ${iss.description}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // 3. Профиль всех подсистем и процессов
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Что нагружает систему — профиль всех подсистем (сортировка по суммарному времени)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          ...subsystems.map((s) {
                            final share = totalMs > 0
                                ? (s.totalMs / totalMs).clamp(0.0, 1.0).toDouble()
                                : 0.0;
                            final isSlow = s.slowCount > 0 ||
                                s.avgMs >= s.slowThresholdMs;
                            final hasErr = s.errorCount > 0;
                            final barColor = hasErr
                                ? const Color(0xFFDC2626)
                                : (isSlow
                                    ? const Color(0xFFD97706)
                                    : const Color(0xFF2563EB));
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 245,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.label,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          '${s.id} · порог ${s.slowThresholdMs.toStringAsFixed(0)} мс${s.lastDetail.isNotEmpty ? ' · ${s.lastDetail}' : ''}',
                                          style: const TextStyle(
                                            fontFamily: 'Consolas',
                                            fontSize: 10.5,
                                            color: Colors.black54,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(
                                    width: 78,
                                    child: Text(
                                      '${s.calls} выз.',
                                      style: const TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11.5,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 96,
                                    child: Text(
                                      'ср ${s.avgMs.toStringAsFixed(2)} мс',
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: isSlow
                                            ? const Color(0xFFDC2626)
                                            : const Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 104,
                                    child: Text(
                                      'макс ${s.maxMs.toStringAsFixed(1)} мс',
                                      style: const TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 96,
                                    child: Text(
                                      'медл:${s.slowCount} ош:${s.errorCount}',
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11,
                                        color: (s.slowCount > 0 ||
                                                s.errorCount > 0)
                                            ? const Color(0xFFDC2626)
                                            : Colors.black45,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: s.calls == 0 ? 0.0 : share,
                                        minHeight: 8,
                                        backgroundColor:
                                            const Color(0xFFE2E8F0),
                                        color: barColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 48,
                                    child: Text(
                                      '${(share * 100).toStringAsFixed(0)}%',
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),

                          if (p.notifySources.isNotEmpty) ...[
                            const Divider(height: 20),
                            const Text(
                              'Источники перерисовок UI (notifyListeners):',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: (p.notifySources.entries.toList()
                                    ..sort(
                                        (a, b) => b.value.compareTo(a.value)))
                                  .take(12)
                                  .map(
                                    (e) => Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF1F5F9),
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: const Color(0xFFCBD5E1),
                                        ),
                                      ),
                                      child: Text(
                                        '${e.key}: ${e.value}',
                                        style: const TextStyle(
                                          fontFamily: 'Consolas',
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // 4. Журнал событий и медленных операций в реальном времени
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Журнал событий, нагрузки и проблем (${filteredEvents.length})',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              SizedBox(
                                width: 220,
                                child: TextField(
                                  controller: _searchCtrl,
                                  decoration: const InputDecoration(
                                    hintText: 'Поиск по журналу...',
                                    prefixIcon: Icon(Icons.search, size: 17),
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _filterChip('ALL', 'Все'),
                              _filterChip('PROBLEMS', 'Проблемы (PERF/WARN/ERR)'),
                              _filterChip('PERF', 'Медленные (PERF)'),
                              _filterChip('MODEM', 'Модем / AT'),
                              _filterChip('SQL', 'SQLite'),
                              _filterChip('VOICE', 'Аудио / Звонки'),
                              _filterChip('UI', 'UI / Кадры'),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            height: 270,
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: filteredEvents.isEmpty
                                ? const Center(
                                    child: Text(
                                      'Событий по выбранному фильтру пока нет.',
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 12,
                                        color: Color(0xFF94A3B8),
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: filteredEvents.length,
                                    itemBuilder: (_, idx) {
                                      final ev = filteredEvents[idx];
                                      final color = ev.level == 'ERR'
                                          ? const Color(0xFFF87171)
                                          : (ev.level == 'PERF' ||
                                                  ev.level == 'WARN'
                                              ? const Color(0xFFFBBF24)
                                              : const Color(0xFF38BDF8));
                                      return SelectableText(
                                        '[${ev.timeLabel}] [${ev.level}] [${ev.category}/${ev.subsystem}] ${ev.message}',
                                        style: TextStyle(
                                          fontFamily: 'Consolas',
                                          fontSize: 11.5,
                                          height: 1.45,
                                          color: color,
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
            ),
        ],
      ),
    );
  }

  Widget _metricCard({
    required String title,
    required String primary,
    required String secondary,
    required Color accent,
    required IconData icon,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              primary,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: accent,
                fontFamily: 'Consolas',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              secondary,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String id, String label) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: _eventFilter == id,
      onSelected: (_) => setState(() => _eventFilter = id),
      visualDensity: VisualDensity.compact,
    );
  }
}
