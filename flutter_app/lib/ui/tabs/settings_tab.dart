import 'package:flutter/material.dart';
import '../../app_version.dart';
import '../../services/app_paths.dart';
import '../../services/modem_controller.dart';
import '../../services/tray_window_service.dart';

class SettingsTab extends StatefulWidget {
  final ModemController controller;
  final TrayWindowService trayService;

  const SettingsTab({
    super.key,
    required this.controller,
    required this.trayService,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  late final TextEditingController _smsIntervalCtrl;
  late final TextEditingController _activePollCtrl;
  late final TextEditingController _idlePollCtrl;
  late final TextEditingController _hiddenPollCtrl;

  ModemController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _smsIntervalCtrl =
        TextEditingController(text: c.settings.smsPollIntervalSec.toString());
    _activePollCtrl =
        TextEditingController(text: c.settings.activePollSec.toString());
    _idlePollCtrl =
        TextEditingController(text: c.settings.idlePollSec.toString());
    _hiddenPollCtrl =
        TextEditingController(text: c.settings.hiddenPollSec.toString());
  }

  @override
  void dispose() {
    _smsIntervalCtrl.dispose();
    _activePollCtrl.dispose();
    _idlePollCtrl.dispose();
    _hiddenPollCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAll() async {
    c.settings.smsPollIntervalSec =
        (int.tryParse(_smsIntervalCtrl.text) ?? 25).clamp(10, 600).toInt();
    c.settings.activePollSec =
        (int.tryParse(_activePollCtrl.text) ?? 6).clamp(3, 120).toInt();
    c.settings.idlePollSec =
        (int.tryParse(_idlePollCtrl.text) ?? 20).clamp(5, 300).toInt();
    c.settings.hiddenPollSec =
        (int.tryParse(_hiddenPollCtrl.text) ?? 45).clamp(10, 600).toInt();
    await c.saveSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Настройки сохранены в UserData/settings.json')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Column(
            children: [
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(icon: Icon(Icons.tune, size: 17), text: 'Основные настройки'),
                  Tab(
                    icon: Icon(Icons.info_outline, size: 17),
                    text: 'О программе и история версий',
                  ),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildGeneralSettings(),
                    _buildAboutAndChangelog(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralSettings() {
    final s = c.settings;

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Подключение и скорость COM-порта',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<int>(
                value: [9600, 19200, 38400, 57600, 115200, 230400, 460800]
                        .contains(s.baudRate)
                    ? s.baudRate
                    : 115200,
                decoration: const InputDecoration(
                  labelText: 'Скорость порта (baud)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [9600, 19200, 38400, 57600, 115200, 230400, 460800]
                    .map((b) => DropdownMenuItem(value: b, child: Text('$b бод')))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => s.baudRate = v);
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.autoConnect,
                onChanged: (v) => setState(() => s.autoConnect = v),
                title: const Text('Автоподключение при появлении USB-модема'),
                subtitle: const Text(
                  'При извлечении модема порт мгновенно освобождается и переподключается при возврате.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),

        const Divider(height: 28),

        const Text(
          'SMS и оповещения (winmm.dll)',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.autoFetchSms,
          onChanged: (v) => setState(() => s.autoFetchSms = v),
          title: const Text('Автоматическая загрузка SMS (+CMTI и по расписанию)'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.deleteSmsFromModemAfterSave,
          onChanged: (v) => setState(() => s.deleteSmsFromModemAfterSave = v),
          title: const Text('Удалять SMS из памяти модема после сохранения в SQLite'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.requestSmsDeliveryReport,
          onChanged: (v) => setState(() => s.requestSmsDeliveryReport = v),
          title: const Text('Запрашивать отчёт о доставке SMS по умолчанию (+CDS)'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: TextField(
                controller: _smsIntervalCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Интервал проверки SMS (сек)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: s.smsSoundEnabled,
                  onChanged: (v) => setState(() => s.smsSoundEnabled = v ?? true),
                ),
                const Text('Звук при новом SMS'),
              ],
            ),
            SizedBox(
              width: 180,
              child: Slider(
                value: s.smsSoundVolume,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                label: '${(s.smsSoundVolume * 100).round()}%',
                onChanged: s.smsSoundEnabled
                    ? (v) => setState(() => s.smsSoundVolume = v)
                    : null,
              ),
            ),
            Text('${(s.smsSoundVolume * 100).round()}%'),
            FilledButton.tonalIcon(
              onPressed: () =>
                  c.audio.playSmsNotification(volume: s.smsSoundVolume),
              icon: const Icon(Icons.volume_up, size: 17),
              label: const Text('Проверить звук SMS'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.smsPopupEnabled,
                onChanged: (v) => setState(() => s.smsPopupEnabled = v),
                title: const Text('Всплывающее окно поверх всех окон при новом SMS'),
                subtitle: const Text(
                  'Показывает компактное уведомление поверх других программ (даже если окно свёрнуто в трей).',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => c.triggerTestSmsPopup(),
              icon: const Icon(Icons.sms_outlined, size: 17),
              label: const Text('Тест окна SMS'),
            ),
          ],
        ),

        const Divider(height: 28),

        const Text(
          'Входящие звонки — звук, громкость и всплывающее окно',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: s.callRingtoneEnabled,
                  onChanged: (v) =>
                      setState(() => s.callRingtoneEnabled = v ?? true),
                ),
                const Text('Звук при входящем звонке'),
              ],
            ),
            SizedBox(
              width: 190,
              child: Slider(
                value: s.callRingtoneVolume,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                label: '${(s.callRingtoneVolume * 100).round()}%',
                onChanged: s.callRingtoneEnabled
                    ? (v) => setState(() => s.callRingtoneVolume = v)
                    : null,
              ),
            ),
            Text('${(s.callRingtoneVolume * 100).round()}%'),
            FilledButton.tonalIcon(
              onPressed: () {
                c.testCallRingtone();
                setState(() {});
              },
              icon: Icon(
                c.audio.isRingtonePlaying ? Icons.stop : Icons.ring_volume,
                size: 17,
              ),
              label: Text(
                c.audio.isRingtonePlaying
                    ? 'Остановить звонок'
                    : 'Проверить звонок',
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.callPopupEnabled,
                onChanged: (v) => setState(() => s.callPopupEnabled = v),
                title: const Text('Всплывающее окно поверх всех окон при входящем звонке'),
                subtitle: const Text(
                  'Показывает номер абонента с кнопками «Принять», «Сбросить» и «Тише» поверх всех программ Windows.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => c.triggerTestCallPopup(),
              icon: const Icon(Icons.call_received, size: 17),
              label: const Text('Тест окна звонка'),
            ),
          ],
        ),

        const Divider(height: 28),

        const Text(
          'Отладка и профилировщик процессов (в реальном времени)',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.debugProfilerEnabled,
          onChanged: (v) async {
            await c.setDebugProfilerEnabled(v);
            if (mounted) setState(() {});
          },
          title: const Text('Включить подробную отладку и мониторинг нагрузки CPU / RAM / подсистем'),
          subtitle: const Text(
            'Когда выключено — таймеры и профилировщик полностью остановлены и не создают никакой нагрузки.',
            style: TextStyle(fontSize: 12),
          ),
        ),

        const Divider(height: 28),

        const Text(
          'Системный трей и снижение нагрузки в простое / при сворачивании',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.minimizeToTrayOnClose,
          onChanged: (v) => setState(() => s.minimizeToTrayOnClose = v),
          title: const Text('Сворачивать в системный трей при нажатии крестика (×)'),
          subtitle: const Text(
            'При закрытии окно скрывается в трей. Восстановление — кликом по иконке в трее.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _activePollCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Активный опрос (сек)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _idlePollCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'В простое >90с (сек)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _hiddenPollCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Окно свёрнуто / в трее (сек)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 22),

        Row(
          children: [
            FilledButton.icon(
              onPressed: _saveAll,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Сохранить настройки'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
              ),
              onPressed: () => widget.trayService.destroyAndExit(),
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: const Text('Выйти полностью из приложения'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAboutAndChangelog() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.usb, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppVersion.appName,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Версия ${AppVersion.version} (${AppVersion.buildDate}) · Портативная сборка Windows x64',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Портативное хранилище UserData (рядом с exe):',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              SelectableText('• Папка данных: ${AppPaths.userDataDir}',
                  style: const TextStyle(fontSize: 12)),
              SelectableText('• База SQLite: ${AppPaths.databaseFile}',
                  style: const TextStyle(fontSize: 12)),
              SelectableText('• Настройки: ${AppPaths.settingsFile}',
                  style: const TextStyle(fontSize: 12)),
              SelectableText('• Таблица Excel: ${AppPaths.excelMainFile}',
                  style: const TextStyle(fontSize: 12)),
              SelectableText('• Голосовые фразы: ${AppPaths.soundsDir}',
                  style: const TextStyle(fontSize: 12)),
              SelectableText('• Экспорт CSV: ${AppPaths.exportsDir}',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'История версий',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...AppVersion.changelog.map(
          (item) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'v${item.version} — ${item.date}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                ...item.highlights.map(
                  (h) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $h', style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
