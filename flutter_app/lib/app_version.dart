class AppVersion {
  static const String appName = 'Huawei E173 Portable Manager';
  static const String version = '2.0.0';
  static const String buildDate = '2026-11-20';

  static String get windowTitle => '$appName v$version';

  static const List<VersionHistoryItem> changelog = [
    VersionHistoryItem(
      version: '2.0.0',
      date: '2026-11-20',
      highlights: [
        'Управление входящими звонками: синтезированный рингтон через winmm.dll с включением/выключением, регулировкой громкости 0–100% и проверкой звука (аналогично SMS).',
        'Всплывающие окна поверх всех окон Windows для новых SMS и входящих звонков (включая компактное мини-окно поверх программ при сворачивании в трей) с возможностью отключения в Настройках.',
        'Полная отладка и профилировщик процессов в реальном времени (CPU, RAM, Win32 Handles, GDI/USER, FPS, фризы кадров, перерисовки UI, время всех подсистем, автоанализ проблем и экспорт отчёта в TXT) с полным отключением без нагрузки.',
        'Конструктор и движок сценариев (USSD номер/баланс с кэшированием и ожиданием SMS, отправка SMS с порогом баланса, паузы, голосовые звонки с действиями по секундам, DTMF, автозапуск по оператору).',
        'Экспорт и пересборка таблицы Excel (UserData/Excel/scenario_results.xlsx, лист «Результаты»), сверка баланса СОВПАЛ / НЕ СОВПАЛ с цветовой подсветкой, настройка колонок, пресеты и резервное сохранение при блокировке файла.',
        'Полноценный PDU-декодер SMS (GSM-7, UCS-2, склейка составных сообщений), SQLite-хранилище со всех SIM, папки Входящие/Отправленные/Корзина, надгробия при удалении навсегда, групповые действия и звуковое оповещение winmm.dll.',
        'Голосовые вызовы (ATD/ATA/ATH/DTMF/CLCC), звуковой COM-порт через winmm.dll с отключением микрофона/динамиков и счётчиками байт, библиотека фраз UserData/Sounds (запись, импорт WAV, воспроизведение в звонок).',
        'USSD с выбором DCS 15/72, сохранёнными командами и пакетным запуском; контакты SIM (CPBR/CPBW); журнал SQLite, экспорт CSV и диагностика фоновых циклов DIAG.',
        'Адаптивный мониторинг USB Hotplug, режим экономии при отсутствии SIM (60 сек) и сворачивании окна, системный трей и портативное хранилище UserData.',
      ],
    ),
    VersionHistoryItem(
      version: '1.1.0',
      date: '2026-11-20',
      highlights: [
        'Исправление USSD для Huawei E173: упаковка GSM 7-bit Packed PDU (AA180C3602), ожидание асинхронных ответов +CUSD и кнопки переключения сети CS+PS.',
      ],
    ),
    VersionHistoryItem(
      version: '1.0.0',
      date: '2026-11-20',
      highlights: [
        'Базовая портативная версия с нативным Win32 FFI драйвером COM-порта (kernel32.dll), обзором модема, SMS, USSD, AT-терминалом и RAS Dial-Up.',
      ],
    ),
  ];
}

class VersionHistoryItem {
  final String version;
  final String date;
  final List<String> highlights;

  const VersionHistoryItem({
    required this.version,
    required this.date,
    required this.highlights,
  });
}
