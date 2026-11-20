import 'package:flutter/material.dart';
import '../app_version.dart';
import '../services/modem_controller.dart';
import '../services/tray_window_service.dart';
import 'tabs/calls_tab.dart';
import 'tabs/contacts_tab.dart';
import 'tabs/dashboard_tab.dart';
import 'tabs/excel_tab.dart';
import 'tabs/scenarios_tab.dart';
import 'tabs/settings_tab.dart';
import 'tabs/sms_tab.dart';
import 'tabs/terminal_logs_tab.dart';
import 'tabs/ussd_tab.dart';

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

  ModemController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerUpdate);
  }

  @override
  void dispose() {
    c.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (c.lastToastMessage != null) {
      final msg = c.lastToastMessage!;
      c.clearToast();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final unread = c.unreadSmsCount;

    return Listener(
      onPointerDown: (_) => c.markUserActivity(),
      onPointerMove: (_) => c.markUserActivity(),
      child: Scaffold(
        body: Row(
          children: [
            // Левое меню с версией и счётчиком непрочитанных SMS
            Container(
              width: 236,
              color: Colors.white,
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
                          style: TextStyle(fontSize: 11, color: Colors.black54),
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
                        _navBtn(8, Icons.settings_outlined, 'Настройки'),
                      ],
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.snapshot.connected
                              ? '${c.snapshot.port} · ${c.snapshot.simStatus}'
                              : 'Модем не подключён',
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
            const VerticalDivider(width: 1),
            // Правая рабочая область
            Expanded(
              child: Column(
                children: [
                  _buildTopBar(),
                  if (c.incomingCallerNumber != null) _buildIncomingCallBanner(),
                  const Divider(height: 1),
                  Expanded(
                    child: IndexedStack(
                      index: _tabIndex,
                      children: [
                        DashboardTab(controller: c),
                        ScenariosTab(controller: c),
                        ExcelTab(controller: c),
                        SmsTab(controller: c),
                        CallsTab(controller: c),
                        UssdTab(controller: c),
                        ContactsTab(controller: c),
                        TerminalLogsTab(controller: c),
                        SettingsTab(
                          controller: c,
                          trayService: widget.trayService,
                        ),
                      ],
                    ),
                  ),
                  _buildFooter(),
                ],
              ),
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
              decoration: const InputDecoration(
                labelText: 'COM-порт Huawei E173',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: portItems,
              onChanged: c.snapshot.connected
                  ? null
                  : (v) => setState(() => c.selectedPort = v),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.outlined(
            tooltip: 'Обновить COM-порты',
            onPressed: c.snapshot.connected ? null : c.scanPorts,
            icon: const Icon(Icons.refresh),
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
            icon: Icon(c.snapshot.connected ? Icons.link_off : Icons.usb),
            label: Text(c.snapshot.connected ? 'Отключить' : 'Подключить'),
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
          FilledButton(
            onPressed: () async {
              await c.modem.answerCall();
              if (c.settings.preferredVoicePort.isNotEmpty) {
                try {
                  c.voice.startVoiceBridge(c.settings.preferredVoicePort);
                } catch (_) {}
              }
              c.incomingCallerNumber = null;
              await c.refreshActiveCalls();
            },
            child: const Text('Принять'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () async {
              await c.modem.hangupCall();
              c.incomingCallerNumber = null;
              await c.refreshActiveCalls();
            },
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
                : 'UserData портативный режим',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
