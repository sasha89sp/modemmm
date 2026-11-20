import 'dart:async';
import 'package:flutter/material.dart';
import '../models/modem_models.dart';
import '../services/huawei_e173_service.dart';
import '../services/portable_config.dart';
import '../services/ras_dialer.dart';
import '../services/win32_serial.dart';

class ModemHomePage extends StatefulWidget {
  const ModemHomePage({super.key});

  @override
  State<ModemHomePage> createState() => _ModemHomePageState();
}

class _ModemHomePageState extends State<ModemHomePage> {
  final Win32SerialPort _serial = Win32SerialPort();
  late final HuaweiE173Service _modem;

  PortableConfig _config = PortableConfig();
  List<ComPortInfo> _ports = [];
  String? _selectedPort;
  bool _connected = false;
  bool _busy = false;
  int _tabIndex = 0;

  ModemInfo _info = const ModemInfo();
  List<SmsMessageItem> _smsList = [];
  final List<String> _atLogs = [];
  String _ussdResponse = '';
  String _rasStatus = 'Отключено';

  final _smsPhoneCtrl = TextEditingController();
  final _smsBodyCtrl = TextEditingController();
  final _ussdCtrl = TextEditingController(text: '*100#');
  final _atCtrl = TextEditingController(text: 'ATI');
  final _apnCtrl = TextEditingController();
  final _nckCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _modem = HuaweiE173Service(_serial, onLog: _appendLog);
    _bootstrap();
  }

  @override
  void dispose() {
    _serial.close();
    _smsPhoneCtrl.dispose();
    _smsBodyCtrl.dispose();
    _ussdCtrl.dispose();
    _atCtrl.dispose();
    _apnCtrl.dispose();
    _nckCtrl.dispose();
    super.dispose();
  }

  void _appendLog(String dir, String line) {
    final now = TimeOfDay.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    setState(() {
      _atLogs.insert(0, '[$ts] $dir  $line');
      if (_atLogs.length > 200) _atLogs.removeLast();
    });
  }

  Future<void> _bootstrap() async {
    _config = await PortableConfig.load();
    _apnCtrl.text = _config.apn;
    await _scanPorts();
    if (_config.autoConnect && _selectedPort != null) {
      await _toggleConnection();
    }
  }

  Future<void> _scanPorts() async {
    final found = await Win32SerialPort.scanPorts();
    setState(() {
      _ports = found;
      if (_config.lastPort.isNotEmpty &&
          found.any((p) => p.port == _config.lastPort)) {
        _selectedPort = _config.lastPort;
      } else if (found.isNotEmpty) {
        _selectedPort = found.first.port;
      } else {
        _selectedPort = null;
      }
    });
  }

  Future<void> _toggleConnection() async {
    if (_connected) {
      _serial.close();
      setState(() => _connected = false);
      _appendLog('INFO', 'COM-порт закрыт');
      return;
    }
    if (_selectedPort == null) {
      _showSnack(
          'Сначала выберите COM-порт (рекомендуется 3G PC UI Interface).');
      return;
    }
    setState(() => _busy = true);
    try {
      _serial.open(_selectedPort!, baudRate: _config.baudRate);
      _config.lastPort = _selectedPort!;
      await _config.save();
      await _modem.initialize();
      final info = await _modem.refreshAll();
      setState(() {
        _connected = true;
        _info = info;
      });
      _showSnack('Подключено к $_selectedPort (${info.model})');
    } catch (e) {
      _serial.close();
      _showSnack('Ошибка: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _refreshStatus() async {
    if (!_connected) return;
    setState(() => _busy = true);
    try {
      final info = await _modem.refreshAll();
      setState(() => _info = info);
    } catch (e) {
      _showSnack('Ошибка обновления: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadSms() async {
    if (!_connected) return;
    setState(() => _busy = true);
    try {
      final list = await _modem.readAllSms();
      setState(() => _smsList = list);
    } catch (e) {
      _showSnack('Ошибка чтения SMS: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendSms() async {
    if (!_connected) return;
    if (_smsPhoneCtrl.text.trim().isEmpty || _smsBodyCtrl.text.trim().isEmpty) {
      _showSnack('Укажите номер получателя и текст сообщения.');
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await _modem.sendSms(_smsPhoneCtrl.text, _smsBodyCtrl.text);
      _showSnack(
          ok ? 'SMS успешно отправлено.' : 'Модем отклонил отправку SMS.');
      if (ok) _smsBodyCtrl.clear();
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendUssd(String code) async {
    if (!_connected) return;
    setState(() {
      _busy = true;
      _ussdResponse = 'Ожидание ответа сети...';
    });
    try {
      final reply = await _modem.sendUssd(code);
      setState(() => _ussdResponse = reply);
    } catch (e) {
      setState(() => _ussdResponse = 'Ошибка USSD: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runManualAt() async {
    if (!_connected || _atCtrl.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await _modem.exec(_atCtrl.text.trim());
    } finally {
      setState(() => _busy = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _tabIndex,
            extended: true,
            minExtendedWidth: 210,
            onDestinationSelected: (idx) {
              setState(() => _tabIndex = idx);
              if (idx == 1 && _connected) _loadSms();
            },
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.router_outlined),
                selectedIcon: Icon(Icons.router),
                label: Text('Обзор и сеть'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.sms_outlined),
                selectedIcon: Icon(Icons.sms),
                label: Text('SMS (Кириллица)'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.dialpad_outlined),
                selectedIcon: Icon(Icons.dialpad),
                label: Text('USSD-запросы'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: Text('Режимы E173'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: Text('AT-терминал'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _buildTopBar(),
                const Divider(height: 1),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      _buildOverviewTab(),
                      _buildSmsTab(),
                      _buildUssdTab(),
                      _buildModesTab(),
                      _buildAtTerminalTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _selectedPort,
              decoration: const InputDecoration(
                labelText: 'COM-порт Huawei E173 (PC UI Interface)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _ports
                  .map((p) => DropdownMenuItem(
                        value: p.port,
                        child: Text(
                          p.isHuaweiPcUi
                              ? '[Рекомендуемый] ${p.displayLabel}'
                              : p.displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged:
                  _connected ? null : (v) => setState(() => _selectedPort = v),
            ),
          ),
          const SizedBox(width: 12),
          IconButton.outlined(
            tooltip: 'Обновить список COM-портов',
            onPressed: _connected ? null : _scanPorts,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _toggleConnection,
            icon: Icon(_connected ? Icons.link_off : Icons.usb),
            label: Text(_connected ? 'Отключить' : 'Подключить'),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Состояние модема Huawei E173',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            OutlinedButton.icon(
              onPressed: _connected && !_busy ? _refreshStatus : null,
              icon: const Icon(Icons.sync),
              label: const Text('Опросить модем'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _metricCard('Оператор', _info.operatorName, _info.networkType),
            _metricCard(
              'Уровень сигнала',
              _info.dbm != null ? '${_info.dbm} dBm' : 'Нет данных',
              'CSQ: ${_info.rssi} / 31 · Делений: ${_info.signalBars}/5',
            ),
            _metricCard('SIM-карта', _info.simStatus, _info.cardLockStatus),
            _metricCard(
              'Прошивка и IMEI',
              _info.imei,
              '${_info.model} · ${_info.revision}',
            ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Подключение к интернету (Windows RAS Dial-Up)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _apnCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Точка доступа APN',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () async {
                        if (_connected) {
                          await _modem.setApn(_apnCtrl.text.trim());
                        }
                        _config.apn = _apnCtrl.text.trim();
                        await _config.save();
                        final out = await RasDialer.connect(
                          dialNumber: _config.dialNumber,
                          username: _config.rasUsername,
                          password: _config.rasPassword,
                        );
                        setState(() => _rasStatus = out);
                      },
                      child: const Text('Подключить интернет'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final out = await RasDialer.disconnect();
                        setState(() => _rasStatus = out);
                      },
                      child: const Text('Разорвать'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Статус RAS: $_rasStatus',
                  style: const TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _metricCard(String title, String value, String subtitle) {
    return SizedBox(
      width: 280,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 6),
              Text(value,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSmsTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _smsPhoneCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Номер (+7...)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _smsBodyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Текст SMS (автокодирование UCS2)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _connected && !_busy ? _sendSms : null,
                child: const Text('Отправить'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _connected && !_busy ? _loadSms : null,
                child: const Text('Обновить'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _smsList.isEmpty
                ? const Center(
                    child: Text(
                        'Нажмите «Обновить», чтобы загрузить SMS с модема.'),
                  )
                : ListView.separated(
                    itemCount: _smsList.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final msg = _smsList[i];
                      return ListTile(
                        title: Text('${msg.sender}  ·  ${msg.timestamp}'),
                        subtitle: Text(msg.body),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await _modem.deleteSms(msg.index);
                            await _loadSms();
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildUssdTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _config.ussdShortcuts
                .map((s) => OutlinedButton(
                      onPressed:
                          _connected && !_busy ? () => _sendUssd(s.code) : null,
                      child: Text('${s.label} (${s.code})'),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _ussdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'USSD-команда',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _connected && !_busy
                    ? () => _sendUssd(_ussdCtrl.text)
                    : null,
                child: const Text('Отправить USSD'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: SelectableText(
              _ussdResponse.isEmpty
                  ? 'Ответ оператора появится здесь.'
                  : _ussdResponse,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModesTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Режим сотовой сети (AT^SYSCFG)',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: _connected
                  ? () => _modem.setNetworkMode('AT^SYSCFG=2,2,3FFFFFFF,1,2')
                  : null,
              child: const Text('Авто (2G / 3G)'),
            ),
            OutlinedButton(
              onPressed: _connected
                  ? () => _modem.setNetworkMode('AT^SYSCFG=14,2,3FFFFFFF,1,2')
                  : null,
              child: const Text('Только 3G WCDMA'),
            ),
            OutlinedButton(
              onPressed: _connected
                  ? () => _modem.setNetworkMode('AT^SYSCFG=13,1,3FFFFFFF,1,2')
                  : null,
              child: const Text('Только 2G GSM'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Композитный USB-режим Huawei E173 (AT^U2DIAG)',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: _connected ? () => _modem.setU2Diag(0) : null,
              child: const Text('Только модем (AT^U2DIAG=0)'),
            ),
            OutlinedButton(
              onPressed: _connected ? () => _modem.setU2Diag(256) : null,
              child: const Text('Модем + MicroSD (AT^U2DIAG=256)'),
            ),
            OutlinedButton(
              onPressed: _connected ? () => _modem.setU2Diag(255) : null,
              child: const Text('Заводской режим (AT^U2DIAG=255)'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Разблокировка NCK и перезагрузка',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 240,
              child: TextField(
                controller: _nckCtrl,
                decoration: const InputDecoration(
                  labelText: '8-значный NCK код',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _connected
                  ? () async {
                      final ok = await _modem.unlockCard(_nckCtrl.text.trim());
                      _showSnack(
                        ok ? 'Код принят модемом.' : 'Ошибка разблокировки.',
                      );
                    }
                  : null,
              child: const Text('Ввести NCK'),
            ),
            const SizedBox(width: 16),
            OutlinedButton(
              onPressed: _connected ? () => _modem.rebootModem() : null,
              child: const Text('Перезагрузить модем (CFUN=1,1)'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAtTerminalTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _atCtrl,
                  onSubmitted: (_) => _runManualAt(),
                  decoration: const InputDecoration(
                    labelText: 'AT-команда (например ATI, AT+CSQ, AT^U2DIAG?)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _connected && !_busy ? _runManualAt : null,
                child: const Text('Выполнить'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => _atLogs.clear()),
                child: const Text('Очистить'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                itemCount: _atLogs.length,
                itemBuilder: (_, i) => SelectableText(
                  _atLogs[i],
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
