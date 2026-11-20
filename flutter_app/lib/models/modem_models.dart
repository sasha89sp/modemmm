class ComPortInfo {
  final String port;
  final String description;
  final String deviceId;
  final bool isHuaweiPcUi;

  const ComPortInfo({
    required this.port,
    required this.description,
    required this.deviceId,
    required this.isHuaweiPcUi,
  });

  String get displayLabel =>
      description.isNotEmpty ? '$port — $description' : port;
}

class ModemInfo {
  final String manufacturer;
  final String model;
  final String revision;
  final String imei;
  final String imsi;
  final String simStatus;
  final String operatorName;
  final int rssi;
  final int? dbm;
  final String networkType;
  final String cardLockStatus;

  const ModemInfo({
    this.manufacturer = 'Huawei',
    this.model = 'E173',
    this.revision = '—',
    this.imei = '—',
    this.imsi = '—',
    this.simStatus = 'Неизвестно',
    this.operatorName = 'Поиск сети...',
    this.rssi = 99,
    this.dbm,
    this.networkType = 'Нет сети',
    this.cardLockStatus = '—',
  });

  int get signalBars {
    if (rssi == 99 || rssi <= 1) return 0;
    if (rssi <= 7) return 1;
    if (rssi <= 13) return 2;
    if (rssi <= 19) return 3;
    if (rssi <= 25) return 4;
    return 5;
  }

  ModemInfo copyWith({
    String? manufacturer,
    String? model,
    String? revision,
    String? imei,
    String? imsi,
    String? simStatus,
    String? operatorName,
    int? rssi,
    int? dbm,
    String? networkType,
    String? cardLockStatus,
  }) {
    return ModemInfo(
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      revision: revision ?? this.revision,
      imei: imei ?? this.imei,
      imsi: imsi ?? this.imsi,
      simStatus: simStatus ?? this.simStatus,
      operatorName: operatorName ?? this.operatorName,
      rssi: rssi ?? this.rssi,
      dbm: dbm ?? this.dbm,
      networkType: networkType ?? this.networkType,
      cardLockStatus: cardLockStatus ?? this.cardLockStatus,
    );
  }
}

class SmsMessageItem {
  final int index;
  final String status;
  final String sender;
  final String timestamp;
  final String body;

  const SmsMessageItem({
    required this.index,
    required this.status,
    required this.sender,
    required this.timestamp,
    required this.body,
  });
}

class UssdShortcut {
  final String label;
  final String code;

  const UssdShortcut({required this.label, required this.code});

  Map<String, dynamic> toJson() => {'label': label, 'code': code};

  factory UssdShortcut.fromJson(Map<String, dynamic> json) {
    return UssdShortcut(
      label: json['label']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
    );
  }
}
