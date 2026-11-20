import 'package:flutter/material.dart';
import '../../models/modem_models.dart';
import '../../services/modem_controller.dart';

class ContactsTab extends StatefulWidget {
  final ModemController controller;

  const ContactsTab({super.key, required this.controller});

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _loading = false;

  ModemController get c => widget.controller;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!c.snapshot.connected || c.snapshot.simMissing) return;
    setState(() => _loading = true);
    try {
      await c.refreshContacts();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openEditor({SimContact? contact}) async {
    final nameCtrl = TextEditingController(text: contact?.name ?? '');
    final phoneCtrl = TextEditingController(text: contact?.phone ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(contact == null
            ? 'Новый контакт на SIM'
            : 'Редактировать контакт #${contact.index}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Имя',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                decoration: const InputDecoration(
                  labelText: 'Номер телефона',
                  hintText: '+79991234567',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Записать на SIM'),
          ),
        ],
      ),
    );

    if (saved == true && phoneCtrl.text.trim().isNotEmpty) {
      final ok = await c.modem.writeSimContact(
        index: contact?.index,
        phone: phoneCtrl.text.trim(),
        name: nameCtrl.text.trim(),
      );
      c.db.logOperation(
        'Контакты SIM',
        contact == null ? 'Добавление' : 'Изменение #${contact.index}',
        ok ? 'OK' : 'Ошибка',
        '${nameCtrl.text.trim()} (${phoneCtrl.text.trim()})',
      );
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = c.snapshot.connected && !c.snapshot.simMissing;
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = c.contacts.where((ct) {
      if (q.isEmpty) return true;
      return ct.name.toLowerCase().contains(q) ||
          ct.phone.toLowerCase().contains(q);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Text(
                    'Контакты SIM-карты (AT+CPBR / AT+CPBW)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Поиск по имени или номеру...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: connected && !_loading ? _reload : null,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: Text(_loading ? 'Чтение SIM...' : 'Загрузить с SIM'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: connected ? () => _openEditor() : null,
                    icon: const Icon(Icons.person_add_outlined, size: 17),
                    label: const Text('Добавить'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        connected
                            ? 'Нажмите «Загрузить с SIM» или добавьте новый контакт.'
                            : 'Подключите модем с SIM-картой для работы с контактами.',
                        style: const TextStyle(color: Colors.black54),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, idx) {
                        final ct = filtered[idx];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFFE2E8F0),
                            foregroundColor: const Color(0xFF0F172A),
                            child: Text('${ct.index}',
                                style: const TextStyle(fontSize: 12)),
                          ),
                          title: Text(
                            ct.name.isEmpty ? '(Без имени)' : ct.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: SelectableText(ct.phone),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Редактировать',
                                icon: const Icon(Icons.edit_outlined, size: 19),
                                onPressed: connected
                                    ? () => _openEditor(contact: ct)
                                    : null,
                              ),
                              IconButton(
                                tooltip: 'Удалить с SIM',
                                icon: const Icon(Icons.delete_outline, size: 19),
                                onPressed: connected
                                    ? () async {
                                        await c.modem.deleteSimContact(ct.index);
                                        c.db.logOperation(
                                          'Контакты SIM',
                                          'Удаление #${ct.index}',
                                          'OK',
                                          ct.name,
                                        );
                                        await _reload();
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
