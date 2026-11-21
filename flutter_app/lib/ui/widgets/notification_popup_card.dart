import 'package:flutter/material.dart';
import '../../services/modem_controller.dart';

/// Компактная карточка всплывающего уведомления поверх всех окон
/// для входящих звонков и новых SMS.
class NotificationPopupCard extends StatelessWidget {
  final PopupNotificationData data;
  final bool standaloneWindowMode;
  final bool ringtoneMuted;
  final VoidCallback onOpenTab;
  final VoidCallback onDismiss;
  final VoidCallback? onAnswerCall;
  final VoidCallback? onRejectCall;
  final VoidCallback? onMuteRingtone;
  final VoidCallback? onMarkSmsRead;

  const NotificationPopupCard({
    super.key,
    required this.data,
    required this.standaloneWindowMode,
    required this.ringtoneMuted,
    required this.onOpenTab,
    required this.onDismiss,
    this.onAnswerCall,
    this.onRejectCall,
    this.onMuteRingtone,
    this.onMarkSmsRead,
  });

  @override
  Widget build(BuildContext context) {
    final isCall = data.type == PopupNotificationType.incomingCall;
    final accent = isCall ? const Color(0xFF15803D) : const Color(0xFF1D4ED8);
    final headerBg = isCall ? const Color(0xFFDCFCE7) : const Color(0xFFDBEAFE);

    final bodyContent = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            data.displaySender,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (data.body.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              data.body.trim(),
              maxLines: isCall ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: Color(0xFF334155),
              ),
            ),
          ],
        ],
      ),
    );

    final content = Material(
      color: Colors.white,
      elevation: standaloneWindowMode ? 0 : 12,
      borderRadius: standaloneWindowMode
          ? BorderRadius.zero
          : BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: accent.withAlpha(115),
            width: standaloneWindowMode ? 2 : 1.5,
          ),
          borderRadius: standaloneWindowMode
              ? BorderRadius.zero
              : BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: standaloneWindowMode ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Шапка уведомления
            Container(
              color: headerBg,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isCall ? Icons.ring_volume : Icons.sms_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          data.title,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: accent,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (data.timestamp.isNotEmpty)
                          Text(
                            data.timestamp,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black54,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть окно уведомления',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onDismiss,
                  ),
                ],
              ),
            ),

            // Содержимое уведомления
            if (standaloneWindowMode)
              Expanded(child: bodyContent)
            else
              bodyContent,

            // Кнопки управления
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
              child: isCall
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF15803D),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: onAnswerCall,
                          icon: const Icon(Icons.call, size: 16),
                          label: const Text('Принять'),
                        ),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFDC2626),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: onRejectCall,
                          icon: const Icon(Icons.call_end, size: 16),
                          label: const Text('Сбросить'),
                        ),
                        if (!ringtoneMuted && onMuteRingtone != null)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: onMuteRingtone,
                            icon: const Icon(Icons.volume_off, size: 16),
                            label: const Text('Тише'),
                          ),
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: onOpenTab,
                          child: const Text('Открыть'),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: onOpenTab,
                          icon: const Icon(Icons.open_in_new, size: 15),
                          label: const Text('Открыть SMS'),
                        ),
                        const SizedBox(width: 8),
                        if (!data.isTest && onMarkSmsRead != null)
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: onMarkSmsRead,
                            child: const Text('Прочитано'),
                          ),
                        const Spacer(),
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: onDismiss,
                          child: const Text('Закрыть'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );

    if (standaloneWindowMode) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: content,
      );
    }

    return SizedBox(width: 410, child: content);
  }
}
