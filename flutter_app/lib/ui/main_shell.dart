import 'package:flutter/material.dart';
import '../app_version.dart';
import '../services/modem_controller.dart';
import '../services/tray_window_service.dart';
import 'tabs/calls_tab.dart';
import 'tabs/contacts_tab.dart';
import 'tabs/dashboard_tab.dart';
import 'tabs/debug_profiler_tab.dart';
import 'tabs/excel_tab.dart';
import 'tabs/scenarios_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/sms_tab.dart';
import 'tabs/terminal_logs_tab.dart';
import 'tabs/ussd_tab.dart';
import 'widgets/notification_popup_card.dart';

class MainShell extends StatefulWidget {
  final ModemController controller;
  final TrayWindowService trayService;

  const MainShell({
    super.key,
    required this.controller,
    required this.trayService,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tabIndex = 0;
  bool _miniPopupMode = false;

  ModemController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerUpdate);

    // Связываем всплывающие окна SMS и звонков с TrayWindowService (Always-On-Top)
    c.onPopupShowRequested = widget.trayService.presentNotificationPopup;
    c.onPopupDismissRequested = widget.trayService.dismissNotificationPopup;
    widget.trayService.onMiniPopupModeChanged = (mini) {
      if (mounted && _miniPopupMode != mini) {
        setState(() => _miniPopupMode = mini);
      }
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.trayService.initTray();
      c.startHardwareAndLoops();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onControllerUpdate);
    c.onPopupShowRequested = null;
    c.onPopupDismissRequested = null;
    widget.trayService.onMiniPopupModeChanged = null;
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (!_miniPopupMode && c.lastToastMessage != null) {
      final msg = c.lastToastMessage!;
      c.clearToast();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    }
    setState(() {});
  }

  Future<void> _openFromPopup(PopupNotificationType type) async {
    final targetTab = type == PopupNotificationType.incomingCall ? 4 : 3;
    setState(() => _tabIndex = targetTab);
    await c.dismissActivePopup(restoreFullWindow: true);
    if (targetTab == 4 && c.snapshot.connected) {
      await c.refreshActiveCalls();
    }
  }

  Widget _buildActiveTab() {
    switch (_tabIndex) {
      case 0:
        return DashboardTab(controller: c);
      case 1:
        return ScenariosTab(controller: c);
      case 2:
        return ExcelTab(controller: c);
      case 3:
        return SmsTab(controller: c);
      case 4:
        return CallsTab(controller: c);
      case 5:
        return UssdTab(controller: c);
      case 6:
        return ContactsTab(controller: c);
      case 7:
        return TerminalLogsTab(controller: c);
      case 8:
        return DebugProfilerTab(controller: c);
      case 9:
        return SettingsTab(
          controller: c,
          trayService: widget.trayService,
        );
      default:
        return DashboardTab(controller: c);
    }
  }

  Widget _buildPopupWidget(PopupNotificationData popup, {required bool standalone}) {
    return NotificationPopupCard(
      data: popup,
      standaloneWindowMode: standalone,
      ringtoneMuted: c.incomingRingtoneMuted,
      onOpenTab: () => _openFromPopup(popup.type),
      onDismiss: () => c.dismissActivePopup(restoreFullWindow: false),
      onAnswerCall: () async {
        setState(() => _tabIndex = 4);
        await c.answerIncomingCall();
      },
      onRejectCall: () => c.rejectIncomingCall(),
      onMuteRingtone: () => c.muteCurrentRingtone(),
      onMarkSmsRead: () {
        c.markAllInboxSmsRead();
        c.dismissActivePopup(restoreFullWindow: false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final popup = c.activePopup;

    // Режим компактного всплывающего окна поверх всех окон Windows (когда программа была в трее/свёрнута)
    if (_miniPopupMode && popup != null) {
      return _buildPopupWidget(popup, standalone: true);
    }

    final unread = c.unreadSmsCount;

    return Listener(
      onPointerDown: (_) => c.markUserActivity(),
      child: Scaffold(
        body: Stack(
          children: [
            Row(
              children: [
                // Левое меню с версией и счётчиком непрочитанных SMS
                Material(
                  color: Colors.white,
                  child: SizedBox(
                    width: 236,
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Huawei E173',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Portable Manager v${AppVersion.version}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.all(8),
                            children: [
                              _navBtn(0, Icons.router_outlined, 'Обзор и режимы'),
                              _navBtn(1, Icons.account_tree_outlined, 'Сценарии'),
                              _navBtn(2, Icons.table_chart_outlined, 'Таблица Excel'),
                              _navBtn(
                                3,
                                Icons.sms_outlined,
                                unread > 0 ? 'SMS ($unread)' : 'SMS',
                              ),
                              _navBtn(4, Icons.call_outlined, 'Звонки и фразы'),
                              _navBtn(5, Icons.dialpad_outlined, 'USSD-запросы'),
                              _navBtn(6, Icons.contacts_outlined, 'Контакты SIM'),
                              _navBtn(7, Icons.terminal_outlined, 'AT и журнал'),
                              _navBtn(
                                8,
                                Icons.bug_report_outlined,
                                c.profiler.enabled
                                    ? 'Отладка (ВКЛ)'
                                    : 'Отладка и нагрузка',
                              ),
                              _navBtn(9, Icons.settings_outlined, 'Настройки'),
                            ],
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.snapshot.connected
                                    ? '${c.snapshot.port} · ${c.snapshot.simStatus}'
                                    : (c.busy
                                        ? 'Подключение...'
                                        : (c.scanningPorts
                                            ? 'Поиск COM-портов...'
                                            : 'Модем не подключён')),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'v${AppVersion.version} · Цикл ${c.currentStatusIntervalSec}с',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                // Правая рабочая область
                Expanded(
                  child: Column(
                    children: [
                      _buildTopBar(),
                      if (c.incomingCallerNumber != null)
                        _buildIncomingCallBanner(),
                      const Divider(height: 1),
                      Expanded(
                        child: _buildActiveTab(),
                      ),
                      _buildFooter(),
                    ],
                  ),
                ),
              ],
            ),

            // Плавающее всплывающее окно SMS/звонка в правом нижнем углу (поверх всех вкладок)
            if (popup != null)
              Positioned(
                right: 18,
                bottom: 42,
                child: _buildPopupWidget(popup, standalone: false),
              ),
          ],
        ),
      ),
    );
  }

  Widget _navBtn(int index, IconData icon, String label) {
    final active = _tabIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        selected: active,
        selectedTileColor: const Color(0xFF0F172A),
        selectedColor: Colors.white,
        leading: Icon(icon, size: 19),
        title: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        onTap: () {
          c.markUserActivity();
          setState(() => _tabIndex = index);
          if (index == 4 && c.snapshot.connected) {
            c.refreshActiveCalls();
            c.refreshVoicePhrases();
          } else if (index == 6 && c.snapshot.connected && c.contacts.isEmpty) {
            c.refreshContacts();
          }
        },
      ),
    );
  }

  Widget _buildTopBar() {
    final portItems = <DropdownMenuItem<String>>[];
    for (final p in c.ports) {
      portItems.add(DropdownMenuItem(
        value: p.port,
        child: Text(
          p.isHuaweiPcUi ? '[PC UI] ${p.displayLabel}' : p.displayLabel,
          overflow: TextOverflow.ellipsis,
        ),
      ));
    }
    if (c.selectedPort != null &&
        !c.ports.any((p) => p.port == c.selectedPort)) {
      portItems.insert(
        0,
        DropdownMenuItem(
          value: c.selectedPort,
          child: Text('${c.selectedPort} (временно отсутствует)'),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: c.selectedPort,
              decoration: InputDecoration(
                labelText: c.scanningPorts
                    ? 'Поиск COM-портов Huawei E173...'
                    : 'COM-порт Huawei E173',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: portItems,
              onChanged: c.snapshot.connected || c.busy
                  ? null
                  : (v) => setState(() => c.selectedPort = v),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.outlined(
            tooltip: 'Обновить COM-порты',
            onPressed: c.snapshot.connected || c.scanningPorts || c.busy
                ? null
                : c.scanPorts,
            icon: c.scanningPorts
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: c.busy
                ? null
                : () {
                    if (c.snapshot.connected) {
                      c.disconnectPort(manual: true);
                    } else if (c.selectedPort != null) {
                      c.connectPort(c.selectedPort!);
                    }
                  },
            icon: c.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(c.snapshot.connected ? Icons.link_off : Icons.usb),
            label: Text(
              c.busy
                  ? 'Подключение...'
                  : (c.snapshot.connected ? 'Отключить' : 'Подключить'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingCallBanner() {
    return Container(
      color: const Color(0xFFDCFCE7),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.ring_volume, color: Color(0xFF166534), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Входящий звонок: ${c.incomingCallerNumber}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF166534),
              ),
            ),
          ),
          if (c.audio.isRingtonePlaying && !c.incomingRingtoneMuted) ...[
            OutlinedButton.icon(
              onPressed: () => c.muteCurrentRingtone(),
              icon: const Icon(Icons.volume_off, size: 16),
              label: const Text('Тише'),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton(
            onPressed: () async {
              setState(() => _tabIndex = 4);
              await c.answerIncomingCall();
            },
            child: const Text('Принять'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => c.rejectIncomingCall(),
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final s = c.snapshot;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          Text(
            '${AppVersion.appName} v${AppVersion.version}',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(width: 16),
          Text(
            s.connected
                ? '${s.operatorName} · ${s.networkType} · ${s.signalPercent}% (${s.dbm != null ? '${s.dbm} dBm' : '—'})'
                : 'Ожидание USB-модема Huawei E173',
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
          const Spacer(),
          Text(
            s.simMissing
                ? 'Эконом-режим: SIM не обнаружена (60с)'
                : (c.profiler.enabled
                    ? 'Профилировщик отладки активен'
                    : 'UserData портативный режим'),
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
