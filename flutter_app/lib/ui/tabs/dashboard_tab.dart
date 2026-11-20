import 'package:flutter/material.dart';
import '../../services/modem_controller.dart';

class DashboardTab extends StatefulWidget {
  final ModemController controller;

  const DashboardTab({super.key, required this.controller});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  late final TextEditingController _apnCtrl;
  final TextEditingController _nckCtrl = TextEditingController();
  bool _manualPolling = false;
  bool _rasBusy = false;

  ModemController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _apnCtrl = TextEditingController(text: c.settings.apn);
  }

  @override
  void dispose() {
    _apnCtrl.dispose();
    _nckCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _manualRefresh() async {
    if (!c.snapshot.connected || _manualPolling) return;
    setState(() => _manualPolling = true);
    try {
      await c.manualRefreshSnapshot();
      _snack('Состояние модема обновлено.');
    } catch (e) {
      _snack('Ошибка опроса: $e');
    } finally {
      if (mounted) setState(() => _manualPolling = false);
    }
  }

  Future<void> _runNetworkMode(String title, String cmd) async {
    if (!c.snapshot.connected) return;
    final ok = await c.modem.setNetworkMode(cmd);
    c.db.logOperation('Режим сети', title, ok ? 'OK' : 'Ошибка', cmd);
    _snack(ok ? 'Применено: $title' : 'Модем отклонил команду $cmd');
  }

  Future<void> _runU2Diag(int mode, String label) async {
    if (!c.snapshot.connected) return;
    final ok = await c.modem.setU2Diag(mode);
    c.db.logOperation('AT^U2DIAG', label, ok ? 'OK' : 'Ошибка', 'AT^U2DIAG=$mode');
    _snack(ok
        ? 'AT^U2DIAG=$mode применён. Переподключите USB-модем для вступления в силу.'
        : 'Ошибка выполнения AT^U2DIAG=$mode');
  }

  @override
  Widget build(BuildContext context) {
    final s = c.snapshot;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (s.simMissing)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFF59E0B)),
            ),
            child: const Row(
              children: [
                Icon(Icons.sim_card_alert_outlined, color: Color(0xFFB45309)),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'SIM-карта не обнаружена: фоновые запросы к сети, синхронизация SMS и автозапуск сценариев отключены. Проверка статуса SIM переведена на интервал 60 секунд.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF92400E),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Карточка состояния модема и сети
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Информация о модеме и сети',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Text(
                      'Интервал опроса: ${c.currentStatusIntervalSec}с',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed:
                          s.connected && !_manualPolling ? _manualRefresh : null,
                      icon: const Icon(Icons.sync, size: 17),
                      label: const Text('Обновить статус'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _infoTile('Модель', '${s.manufacturer} ${s.model}', Icons.usb),
                    _infoTile('IMEI', s.imei, Icons.fingerprint),
                    _infoTile('Прошивка', s.revision, Icons.memory),
                    _infoTile('Состояние SIM', s.simStatus,
                        s.simMissing ? Icons.sim_card_alert : Icons.sim_card),
                    _infoTile('Оператор', s.operatorName, Icons.cell_tower),
                    _infoTile('Регистрация', s.regStatus,
                        s.isRegistered ? Icons.check_circle_outline : Icons.error_outline),
                    _infoTile(
                      'Уровень сигнала',
                      s.connected && !s.simMissing
                          ? '${s.signalPercent}% (${s.dbm != null ? '${s.dbm} dBm' : '—'}) · ${s.signalBars}/5'
                          : '—',
                      Icons.signal_cellular_alt,
                    ),
                    _infoTile('Сеть / Блокировка',
                        '${s.networkType} · ${s.cardLockStatus}', Icons.network_cell),
                  ],
                ),
                if (s.connected && !s.simMissing) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Text('Сигнал: ', style: TextStyle(fontSize: 12)),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: s.signalPercent / 100.0,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${s.signalPercent}% (${s.dbm ?? '—'} dBm)',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Две колонки: Режимы сети + RAS Dial-Up / Администрирование
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Режим сети Huawei E173 (AT^SYSCFG)',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Для работы USSD и голосовых звонков требуется домен CS+PS (2G или Авто 2G/3G).',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: s.connected
                                ? () => _runNetworkMode(
                                      'Авто 2G/3G (CS+PS)',
                                      'AT^SYSCFG=2,0,3FFFFFFF,1,2',
                                    )
                                : null,
                            child: const Text('Авто 2G/3G (CS+PS)'),
                          ),
                          FilledButton.tonal(
                            onPressed: s.connected
                                ? () => _runNetworkMode(
                                      'Приоритет 3G WCDMA',
                                      'AT^SYSCFG=2,2,3FFFFFFF,1,2',
                                    )
                                : null,
                            child: const Text('Приоритет 3G'),
                          ),
                          FilledButton.tonal(
                            onPressed: s.connected
                                ? () => _runNetworkMode(
                                      'Только 3G (WCDMA)',
                                      'AT^SYSCFG=14,2,3FFFFFFF,1,2',
                                    )
                                : null,
                            child: const Text('Только 3G'),
                          ),
                          FilledButton.tonal(
                            onPressed: s.connected
                                ? () => _runNetworkMode(
                                      'Только 2G (GSM / USSD)',
                                      'AT^SYSCFG=13,1,3FFFFFFF,1,2',
                                    )
                                : null,
                            child: const Text('Только 2G GSM'),
                          ),
                        ],
                      ),
                      const Divider(height: 28),
                      const Text(
                        'Композиция USB (AT^U2DIAG)',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: s.connected
                                ? () => _runU2Diag(0, 'Только модем (0)')
                                : null,
                            child: const Text('Только модем (0)'),
                          ),
                          OutlinedButton(
                            onPressed: s.connected
                                ? () => _runU2Diag(256, 'Модем + MicroSD (256)')
                                : null,
                            child: const Text('Модем + SD (256)'),
                          ),
                          OutlinedButton(
                            onPressed: s.connected
                                ? () => _runU2Diag(255, 'Заводской CD+SD (255)')
                                : null,
                            child: const Text('Заводской (255)'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Интернет RAS Dial-Up (Windows)',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _apnCtrl,
                              decoration: const InputDecoration(
                                labelText: 'APN оператора',
                                hintText: 'internet / internet.mts.ru',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _rasBusy
                                ? null
                                : () async {
                                    setState(() => _rasBusy = true);
                                    try {
                                      await c.connectRasInternet(_apnCtrl.text);
                                    } finally {
                                      if (mounted) {
                                        setState(() => _rasBusy = false);
                                      }
                                    }
                                  },
                            child: const Text('Подключить'),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton(
                            onPressed: _rasBusy
                                ? null
                                : () async {
                                    setState(() => _rasBusy = true);
                                    try {
                                      await c.disconnectRasInternet();
                                    } finally {
                                      if (mounted) {
                                        setState(() => _rasBusy = false);
                                      }
                                    }
                                  },
                            child: const Text('Разорвать'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Статус RAS: ${c.rasStatus}',
                        style: const TextStyle(fontSize: 12, color: Colors.black87),
                      ),
                      const Divider(height: 28),
                      const Text(
                        'Разблокировка NCK и перезагрузка',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _nckCtrl,
                              decoration: const InputDecoration(
                                labelText: 'NCK-код (8 цифр)',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: s.connected
                                ? () async {
                                    final code = _nckCtrl.text.trim();
                                    if (code.isEmpty) return;
                                    final ok = await c.modem.unlockCard(code);
                                    _snack(ok
                                        ? 'Код разблокировки принят (AT^CARDLOCK).'
                                        : 'Модем отклонил NCK-код.');
                                  }
                                : null,
                            child: const Text('Разблокировать'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: s.connected
                                ? () async {
                                    await c.modem.rebootModem();
                                    c.db.logOperation(
                                        'Модем', 'Перезагрузка AT+CFUN=1,1', 'OK');
                                    _snack('Команда перезагрузки отправлена.');
                                  }
                                : null,
                            icon: const Icon(Icons.restart_alt, size: 17),
                            label: const Text('Перезагрузить'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _infoTile(String label, String value, IconData icon) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF0F172A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
