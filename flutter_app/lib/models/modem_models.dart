class ComPortInfo {
  final String port;
  final String description;
  final String deviceId;
  final bool isHuaweiPcUi;
  final bool isHuaweiModem;
  final bool isHuaweiVoiceCandidate;

  const ComPortInfo({
    required this.port,
    required this.description,
    required this.deviceId,
    required this.isHuaweiPcUi,
    this.isHuaweiModem = false,
    this.isHuaweiVoiceCandidate = false,
  });

  String get displayLabel =>
      description.isNotEmpty ? '$port — $description' : port;

  int get priorityScore {
    if (isHuaweiPcUi) return 100;
    if (isHuaweiModem) return 80;
    if (isHuaweiVoiceCandidate) return 70;
    if (deviceId.toUpperCase().contains('VID_12D1')) return 60;
    return 10;
  }
}

class ModemSnapshot {
  final bool connected;
  final String port;
  final String manufacturer;
  final String model;
  final String revision;
  final String imei;
  final String imsi;
  final String simStatus;
  final bool simMissing;
  final String operatorName;
  final String regStatus;
  final bool isRegistered;
  final int rssi;
  final int? dbm;
  final int signalPercent;
  final String networkType;
  final String cardLockStatus;

  const ModemSnapshot({
    this.connected = false,
    this.port = '',
    this.manufacturer = 'Huawei',
    this.model = 'E173',
    this.revision = '—',
    this.imei = '—',
    this.imsi = '—',
    this.simStatus = 'Не подключён',
    this.simMissing = false,
    this.operatorName = '—',
    this.regStatus = 'Нет регистрации',
    this.isRegistered = false,
    this.rssi = 99,
    this.dbm,
    this.signalPercent = 0,
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

  ModemSnapshot copyWith({
    bool? connected,
    String? port,
    String? manufacturer,
    String? model,
    String? revision,
    String? imei,
    String? imsi,
    String? simStatus,
    bool? simMissing,
    String? operatorName,
    String? regStatus,
    bool? isRegistered,
    int? rssi,
    int? dbm,
    int? signalPercent,
    String? networkType,
    String? cardLockStatus,
  }) {
    return ModemSnapshot(
      connected: connected ?? this.connected,
      port: port ?? this.port,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      revision: revision ?? this.revision,
      imei: imei ?? this.imei,
      imsi: imsi ?? this.imsi,
      simStatus: simStatus ?? this.simStatus,
      simMissing: simMissing ?? this.simMissing,
      operatorName: operatorName ?? this.operatorName,
      regStatus: regStatus ?? this.regStatus,
      isRegistered: isRegistered ?? this.isRegistered,
      rssi: rssi ?? this.rssi,
      dbm: dbm ?? this.dbm,
      signalPercent: signalPercent ?? this.signalPercent,
      networkType: networkType ?? this.networkType,
      cardLockStatus: cardLockStatus ?? this.cardLockStatus,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ModemSnapshot &&
        other.connected == connected &&
        other.port == port &&
        other.manufacturer == manufacturer &&
        other.model == model &&
        other.revision == revision &&
        other.imei == imei &&
        other.imsi == imsi &&
        other.simStatus == simStatus &&
        other.simMissing == simMissing &&
        other.operatorName == operatorName &&
        other.regStatus == regStatus &&
        other.isRegistered == isRegistered &&
        other.rssi == rssi &&
        other.dbm == dbm &&
        other.signalPercent == signalPercent &&
        other.networkType == networkType &&
        other.cardLockStatus == cardLockStatus;
  }

  @override
  int get hashCode => Object.hash(
        connected,
        port,
        model,
        revision,
        imei,
        imsi,
        simStatus,
        simMissing,
        operatorName,
        regStatus,
        isRegistered,
        rssi,
        dbm,
        networkType,
        cardLockStatus,
      );
}

class SmsRecord {
  final int id;
  final String fingerprint;
  final String simImsi;
  final String folder; // 'inbox', 'sent', 'trash'
  final String prevFolder;
  final String address;
  final String body;
  final String timestamp;
  final bool isRead;
  final int? modemIndex;
  final String deliveryStatus;

  const SmsRecord({
    required this.id,
    required this.fingerprint,
    required this.simImsi,
    required this.folder,
    required this.prevFolder,
    required this.address,
    required this.body,
    required this.timestamp,
    required this.isRead,
    this.modemIndex,
    this.deliveryStatus = '',
  });
}

class SimContact {
  final int index;
  final String name;
  final String phone;

  const SimContact({
    required this.index,
    required this.name,
    required this.phone,
  });
}

class ActiveCallInfo {
  final int id;
  final int dir; // 0=MO, 1=MT
  final int state; // 0=active,1=held,2=dialing,3=alerting,4=incoming,5=waiting
  final String number;

  const ActiveCallInfo({
    required this.id,
    required this.dir,
    required this.state,
    required this.number,
  });

  String get stateLabel {
    switch (state) {
      case 0:
        return 'Активен (разговор)';
      case 1:
        return 'На удержании';
      case 2:
        return 'Набор номера';
      case 3:
        return 'Гудки';
      case 4:
        return 'Входящий звонок';
      case 5:
        return 'Ожидание';
      default:
        return 'Статус $state';
    }
  }
}

class SmsDiagnostics {
  final String cnmi;
  final String cpms;
  final int cmtiCount;
  final DateTime? lastSyncAt;

  const SmsDiagnostics({
    this.cnmi = '—',
    this.cpms = '—',
    this.cmtiCount = 0,
    this.lastSyncAt,
  });
}

class OperationLogEntry {
  final int id;
  final String createdAt;
  final String category;
  final String action;
  final String result;
  final String details;

  const OperationLogEntry({
    required this.id,
    required this.createdAt,
    required this.category,
    required this.action,
    required this.result,
    required this.details,
  });
}

class SystemLogEntry {
  final int id;
  final String createdAt;
  final String level; // TX, RX, INFO, WARN, ERR, DIAG
  final String message;

  const SystemLogEntry({
    required this.id,
    required this.createdAt,
    required this.level,
    required this.message,
  });
}

class DiagMetric {
  final String loopName;
  final int lastDurationMs;
  final double avgDurationMs;
  final int maxDurationMs;
  final int executions;
  final int currentIntervalSec;
  final String stateNote;

  const DiagMetric({
    required this.loopName,
    required this.lastDurationMs,
    required this.avgDurationMs,
    required this.maxDurationMs,
    required this.executions,
    required this.currentIntervalSec,
    required this.stateNote,
  });
}
