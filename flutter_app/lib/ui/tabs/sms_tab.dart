import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/modem_models.dart';
import '../../services/modem_controller.dart';

class SmsTab extends StatefulWidget {
  final ModemController controller;

  const SmsTab({super.key, required this.controller});

  @override
  State<SmsTab> createState() => _SmsTabState();
}

class _SmsTabState extends State<SmsTab> {
  String _folder = 'inbox'; // inbox | sent | trash
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _toCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final Set<int> _selectedIds = {};
  bool _syncing = false;
  bool _sending = false;

  ModemController get c => widget.controller;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _toCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  List<SmsRecord> _loadFiltered() {
    if (!c.initialized) return [];
    return c.db.getMessages(folder: _folder, search: _searchCtrl.text);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _syncNow() async {
    if (!c.snapshot.connected || c.snapshot.simMissing) return;
    setState(() => _syncing = true);
    try {
      final count = await c.syncSmsFromModem(silent: false);
      await c.refreshSmsDiagnostics();
      _snack(count > 0 ? 'Загружено новых SMS: $count' : 'Новых SMS на модеме нет.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _sendSms() async {
    final phone = _toCtrl.text.trim();
    final text = _bodyCtrl.text.trim();
    if (phone.isEmpty || text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final ok = await c.sendSmsAndStore(phone, text);
      if (ok) {
        _bodyCtrl.clear();
        _snack('SMS отправлено на $phone');
      } else {
        _snack('Не удалось отправить SMS на $phone');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _bulkCopy(List<SmsRecord> visible) async {
    final picked = visible.where((m) => _selectedIds.contains(m.id)).toList();
    if (picked.isEmpty) return;
    final text = picked
        .map((m) => '[${m.timestamp}] ${m.address}: ${m.body}')
        .join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Скопировано сообщений: ${picked.length}');
  }

  @override
  Widget build(BuildContext context) {
    final messages = _loadFiltered();
    final allSelected =
        messages.isNotEmpty && messages.every((m) => _selectedIds.contains(m.id));
    final unread = c.unreadSmsCount;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Верхняя панель: папки, поиск, синхронизация и диагностика
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'inbox',
                            icon: const Icon(Icons.inbox_outlined, size: 17),
                            label: Text(unread > 0 ? 'Входящие ($unread)' : 'Входящие'),
                          ),
                          const ButtonSegment(
                            value: 'sent',
                            icon: Icon(Icons.send_outlined, size: 17),
                            label: Text('Отправленные'),
                          ),
                          const ButtonSegment(
                            value: 'trash',
                            icon: Icon(Icons.delete_outline, size: 17),
                            label: Text('Корзина'),
                          ),
                        ],
                        selected: {_folder},
                        onSelectionChanged: (set) {
                          setState(() {
                            _folder = set.first;
                            _selectedIds.clear();
                          });
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search, size: 18),
                            hintText: 'Поиск по номеру, тексту или IMSI...',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        onPressed:
                            c.snapshot.connected && !c.snapshot.simMissing && !_syncing
                                ? _syncNow
                                : null,
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: Text(_syncing ? 'Чтение PDU...' : 'Синхронизировать PDU'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Диагностика SMS (+CNMI?, +CPMS?, +CMTI)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.troubleshoot, size: 16, color: Colors.black54),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'CNMI: ${c.smsDiag.cnmi}   |   CPMS: ${c.smsDiag.cpms}   |   +CMTI событий: ${c.smsDiag.cmtiCount}',
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11.5,
                              color: Colors.black87,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: c.snapshot.connected ? c.refreshSmsDiagnostics : null,
                          child: const Text('Опросить CNMI/CPMS',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // Групповые действия + список SMS + форма отправки
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Список SMS с чекбоксами и групповыми действиями
                Expanded(
                  flex: 3,
                  child: Card(
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: allSelected,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedIds
                                          .addAll(messages.map((m) => m.id));
                                    } else {
                                      _selectedIds.clear();
                                    }
                                  });
                                },
                              ),
                              Text(
                                'Выбрано: ${_selectedIds.length} из ${messages.length}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(width: 12),
                              if (_selectedIds.isNotEmpty) ...[
                                OutlinedButton(
                                  onPressed: () => _bulkCopy(messages),
                                  child: const Text('Копировать'),
                                ),
                                const SizedBox(width: 6),
                                if (_folder == 'inbox') ...[
                                  OutlinedButton(
                                    onPressed: () {
                                      c.markSmsRead(_selectedIds.toList(),
                                          read: true);
                                      setState(() => _selectedIds.clear());
                                    },
                                    child: const Text('Прочитано'),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                if (_folder != 'trash') ...[
                                  OutlinedButton(
                                    onPressed: () {
                                      c.moveSmsToTrash(_selectedIds.toList());
                                      setState(() => _selectedIds.clear());
                                    },
                                    child: const Text('В корзину'),
                                  ),
                                ] else ...[
                                  OutlinedButton(
                                    onPressed: () {
                                      c.restoreSmsFromTrash(
                                          _selectedIds.toList());
                                      setState(() => _selectedIds.clear());
                                    },
                                    child: const Text('Восстановить'),
                                  ),
                                  const SizedBox(width: 6),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFDC2626),
                                    ),
                                    onPressed: () {
                                      c.deleteSmsPermanently(
                                          _selectedIds.toList());
                                      setState(() => _selectedIds.clear());
                                      _snack(
                                          'Удалено навсегда (записаны надгробия — с модема не вернутся).');
                                    },
                                    child: const Text('Удалить навсегда'),
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                        Expanded(
                          child: messages.isEmpty
                              ? const Center(
                                  child: Text(
                                      'В этой папке пока нет сообщений.'),
                                )
                              : ListView.separated(
                                  itemCount: messages.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (_, idx) {
                                    final m = messages[idx];
                                    final checked = _selectedIds.contains(m.id);
                                    return ListTile(
                                      leading: Checkbox(
                                        value: checked,
                                        onChanged: (v) {
                                          setState(() {
                                            if (v == true) {
                                              _selectedIds.add(m.id);
                                            } else {
                                              _selectedIds.remove(m.id);
                                            }
                                          });
                                        },
                                      ),
                                      title: Row(
                                        children: [
                                          if (!m.isRead && _folder == 'inbox')
                                            Container(
                                              width: 8,
                                              height: 8,
                                              margin:
                                                  const EdgeInsets.only(right: 6),
                                              decoration: const BoxDecoration(
                                                color: Color(0xFF2563EB),
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          Text(
                                            m.address,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: m.isRead
                                                  ? FontWeight.w500
                                                  : FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            m.timestamp,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.black54),
                                          ),
                                          if (m.simImsi.isNotEmpty &&
                                              m.simImsi != '—') ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              'SIM ${m.simImsi.length > 6 ? m.simImsi.substring(m.simImsi.length - 6) : m.simImsi}',
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.black45),
                                            ),
                                          ],
                                          const Spacer(),
                                          if (m.deliveryStatus.isNotEmpty)
                                            Text(
                                              m.deliveryStatus,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Color(0xFF0F766E)),
                                            ),
                                        ],
                                      ),
                                      subtitle: Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: SelectableText(
                                          m.body,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              color: Colors.black87),
                                        ),
                                      ),
                                      onTap: () {
                                        if (!m.isRead && _folder == 'inbox') {
                                          c.markSmsRead([m.id], read: true);
                                          setState(() {});
                                        }
                                      },
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 14),

                // Правая колонка: отправка SMS
                SizedBox(
                  width: 310,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Отправить SMS (UCS-2 Кириллица)',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _toCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Номер получателя',
                              hintText: '+79991234567',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _bodyCtrl,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: 'Текст сообщения',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: c.settings.requestSmsDeliveryReport,
                            onChanged: (v) async {
                              c.settings.requestSmsDeliveryReport = v ?? false;
                              await c.saveSettings();
                              setState(() {});
                            },
                            title: const Text(
                              'Запрашивать отчёт о доставке (+CDS)',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: c.snapshot.connected &&
                                      !c.snapshot.simMissing &&
                                      !_sending
                                  ? _sendSms
                                  : null,
                              icon: const Icon(Icons.send, size: 17),
                              label: Text(_sending ? 'Отправка...' : 'Отправить SMS'),
                            ),
                          ),
                        ],
                      ),
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
}
