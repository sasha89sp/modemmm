import 'dart:convert';

enum ScenarioStepType {
  detectOwnNumberUssd,
  customUssd,
  checkBalanceUssd,
  sendSms,
  pause,
  voiceCall,
  sendDtmf,
}

extension ScenarioStepTypeX on ScenarioStepType {
  String get label {
    switch (this) {
      case ScenarioStepType.detectOwnNumberUssd:
        return 'Определить свой номер (USSD)';
      case ScenarioStepType.customUssd:
        return 'Произвольный USSD-запрос';
      case ScenarioStepType.checkBalanceUssd:
        return 'Проверить баланс (USSD + SMS)';
      case ScenarioStepType.sendSms:
        return 'Отправить SMS';
      case ScenarioStepType.pause:
        return 'Пауза';
      case ScenarioStepType.voiceCall:
        return 'Голосовой вызов';
      case ScenarioStepType.sendDtmf:
        return 'Отправить DTMF';
    }
  }
}

class CallSecondAction {
  final int atSecond;
  final String kind; // 'phrase' | 'dtmf'
  final String value; // имя файла фразы или DTMF-цифры

  const CallSecondAction({
    required this.atSecond,
    required this.kind,
    required this.value,
  });

  Map<String, dynamic> toJson() => {
        'atSecond': atSecond,
        'kind': kind,
        'value': value,
      };

  factory CallSecondAction.fromJson(Map<String, dynamic> json) =>
      CallSecondAction(
        atSecond: (json['atSecond'] as num?)?.toInt() ?? 5,
        kind: json['kind']?.toString() ?? 'dtmf',
        value: json['value']?.toString() ?? '',
      );
}

class ScenarioStep {
  final String id;
  final ScenarioStepType type;
  final String title;

  // USSD
  final String ussdCode;
  final int ussdDcs; // 15 or 72

  // Balance SMS wait fallback
  final bool waitSmsIfNoBalance;
  final int smsWaitTimeoutSec;
  final String smsSenderFilter;

  // Send SMS
  final String smsRecipient;
  final String smsBody;
  final bool checkMinBalance;
  final double minBalanceThreshold;

  // Pause
  final int pauseSec;

  // Voice Call
  final String callNumber;
  final int callDurationSec;
  final List<CallSecondAction> callActions;

  // DTMF
  final String dtmfDigits;

  const ScenarioStep({
    required this.id,
    required this.type,
    this.title = '',
    this.ussdCode = '*100#',
    this.ussdDcs = 15,
    this.waitSmsIfNoBalance = false,
    this.smsWaitTimeoutSec = 30,
    this.smsSenderFilter = '',
    this.smsRecipient = '',
    this.smsBody = '',
    this.checkMinBalance = false,
    this.minBalanceThreshold = 10.0,
    this.pauseSec = 5,
    this.callNumber = '',
    this.callDurationSec = 20,
    this.callActions = const [],
    this.dtmfDigits = '1',
  });

  ScenarioStep copyWith({
    String? id,
    ScenarioStepType? type,
    String? title,
    String? ussdCode,
    int? ussdDcs,
    bool? waitSmsIfNoBalance,
    int? smsWaitTimeoutSec,
    String? smsSenderFilter,
    String? smsRecipient,
    String? smsBody,
    bool? checkMinBalance,
    double? minBalanceThreshold,
    int? pauseSec,
    String? callNumber,
    int? callDurationSec,
    List<CallSecondAction>? callActions,
    String? dtmfDigits,
  }) {
    return ScenarioStep(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      ussdCode: ussdCode ?? this.ussdCode,
      ussdDcs: ussdDcs ?? this.ussdDcs,
      waitSmsIfNoBalance: waitSmsIfNoBalance ?? this.waitSmsIfNoBalance,
      smsWaitTimeoutSec: smsWaitTimeoutSec ?? this.smsWaitTimeoutSec,
      smsSenderFilter: smsSenderFilter ?? this.smsSenderFilter,
      smsRecipient: smsRecipient ?? this.smsRecipient,
      smsBody: smsBody ?? this.smsBody,
      checkMinBalance: checkMinBalance ?? this.checkMinBalance,
      minBalanceThreshold: minBalanceThreshold ?? this.minBalanceThreshold,
      pauseSec: pauseSec ?? this.pauseSec,
      callNumber: callNumber ?? this.callNumber,
      callDurationSec: callDurationSec ?? this.callDurationSec,
      callActions: callActions ?? this.callActions,
      dtmfDigits: dtmfDigits ?? this.dtmfDigits,
    );
  }

  String get summary {
    switch (type) {
      case ScenarioStepType.detectOwnNumberUssd:
        return 'USSD $ussdCode (DCS $ussdDcs)';
      case ScenarioStepType.customUssd:
        return 'USSD $ussdCode (DCS $ussdDcs)';
      case ScenarioStepType.checkBalanceUssd:
        return waitSmsIfNoBalance
            ? 'USSD $ussdCode · ждать SMS ${smsWaitTimeoutSec}с${smsSenderFilter.isNotEmpty ? ' от "$smsSenderFilter"' : ''}'
            : 'USSD $ussdCode (DCS $ussdDcs)';
      case ScenarioStepType.sendSms:
        return 'На $smsRecipient: "${smsBody.length > 28 ? '${smsBody.substring(0, 28)}...' : smsBody}"${checkMinBalance ? ' (порог >= $minBalanceThreshold)' : ''}';
      case ScenarioStepType.pause:
        return 'Ожидание $pauseSec сек';
      case ScenarioStepType.voiceCall:
        return 'Звонок $callNumber · ${callDurationSec}с · действий: ${callActions.length}';
      case ScenarioStepType.sendDtmf:
        return 'DTMF: $dtmfDigits';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'ussdCode': ussdCode,
        'ussdDcs': ussdDcs,
        'waitSmsIfNoBalance': waitSmsIfNoBalance,
        'smsWaitTimeoutSec': smsWaitTimeoutSec,
        'smsSenderFilter': smsSenderFilter,
        'smsRecipient': smsRecipient,
        'smsBody': smsBody,
        'checkMinBalance': checkMinBalance,
        'minBalanceThreshold': minBalanceThreshold,
        'pauseSec': pauseSec,
        'callNumber': callNumber,
        'callDurationSec': callDurationSec,
        'callActions': callActions.map((a) => a.toJson()).toList(),
        'dtmfDigits': dtmfDigits,
      };

  factory ScenarioStep.fromJson(Map<String, dynamic> json) {
    final typeName = json['type']?.toString() ?? 'customUssd';
    final parsedType = ScenarioStepType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => ScenarioStepType.customUssd,
    );
    return ScenarioStep(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: parsedType,
      title: json['title']?.toString() ?? '',
      ussdCode: json['ussdCode']?.toString() ?? '*100#',
      ussdDcs: (json['ussdDcs'] as num?)?.toInt() ?? 15,
      waitSmsIfNoBalance: json['waitSmsIfNoBalance'] as bool? ?? false,
      smsWaitTimeoutSec: (json['smsWaitTimeoutSec'] as num?)?.toInt() ?? 30,
      smsSenderFilter: json['smsSenderFilter']?.toString() ?? '',
      smsRecipient: json['smsRecipient']?.toString() ?? '',
      smsBody: json['smsBody']?.toString() ?? '',
      checkMinBalance: json['checkMinBalance'] as bool? ?? false,
      minBalanceThreshold:
          (json['minBalanceThreshold'] as num?)?.toDouble() ?? 10.0,
      pauseSec: (json['pauseSec'] as num?)?.toInt() ?? 5,
      callNumber: json['callNumber']?.toString() ?? '',
      callDurationSec: (json['callDurationSec'] as num?)?.toInt() ?? 20,
      callActions: ((json['callActions'] as List<dynamic>?) ?? [])
          .map((e) => CallSecondAction.fromJson(e as Map<String, dynamic>))
          .toList(),
      dtmfDigits: json['dtmfDigits']?.toString() ?? '1',
    );
  }
}

class ScenarioDefinition {
  final String id;
  final String name;
  final bool stopOnError;
  final bool autoRunOnRegister;
  final String operatorFilter;
  final List<ScenarioStep> steps;

  const ScenarioDefinition({
    required this.id,
    required this.name,
    this.stopOnError = false,
    this.autoRunOnRegister = false,
    this.operatorFilter = '',
    required this.steps,
  });

  ScenarioDefinition copyWith({
    String? id,
    String? name,
    bool? stopOnError,
    bool? autoRunOnRegister,
    String? operatorFilter,
    List<ScenarioStep>? steps,
  }) {
    return ScenarioDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      stopOnError: stopOnError ?? this.stopOnError,
      autoRunOnRegister: autoRunOnRegister ?? this.autoRunOnRegister,
      operatorFilter: operatorFilter ?? this.operatorFilter,
      steps: steps ?? this.steps,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'stopOnError': stopOnError,
        'autoRunOnRegister': autoRunOnRegister,
        'operatorFilter': operatorFilter,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory ScenarioDefinition.fromJson(Map<String, dynamic> json) =>
      ScenarioDefinition(
        id: json['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name']?.toString() ?? 'Сценарий',
        stopOnError: json['stopOnError'] as bool? ?? false,
        autoRunOnRegister: json['autoRunOnRegister'] as bool? ?? false,
        operatorFilter: json['operatorFilter']?.toString() ?? '',
        steps: ((json['steps'] as List<dynamic>?) ?? [])
            .map((e) => ScenarioStep.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static String encodeSteps(List<ScenarioStep> steps) =>
      jsonEncode(steps.map((s) => s.toJson()).toList());

  static List<ScenarioStep> decodeSteps(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => ScenarioStep.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class ScenarioRunRecord {
  final int id;
  final String startedAt;
  final String scenarioName;
  final String operatorName;
  final String phoneNumber;
  final String imei;
  final String imsi;
  final double? firstBalance;
  final double? lastBalance;
  final double? balanceDiff;
  final String balanceMatchStatus; // 'СОВПАЛ', 'НЕ СОВПАЛ', 'Н/Д'
  final String status; // 'УСПЕШНО', 'С ОШИБКАМИ', 'ПРЕРВАН'
  final int durationSec;
  final String errorText;
  final String stepSummary;

  const ScenarioRunRecord({
    required this.id,
    required this.startedAt,
    required this.scenarioName,
    required this.operatorName,
    required this.phoneNumber,
    required this.imei,
    required this.imsi,
    this.firstBalance,
    this.lastBalance,
    this.balanceDiff,
    required this.balanceMatchStatus,
    required this.status,
    required this.durationSec,
    required this.errorText,
    required this.stepSummary,
  });

  String fieldValue(String key) {
    switch (key) {
      case 'startedAt':
        return startedAt;
      case 'scenarioName':
        return scenarioName;
      case 'operatorName':
        return operatorName;
      case 'phoneNumber':
        return phoneNumber;
      case 'imei':
        return imei;
      case 'imsi':
        return imsi;
      case 'firstBalance':
        return firstBalance != null ? firstBalance!.toStringAsFixed(2) : '';
      case 'lastBalance':
        return lastBalance != null ? lastBalance!.toStringAsFixed(2) : '';
      case 'balanceDiff':
        return balanceDiff != null ? balanceDiff!.toStringAsFixed(2) : '';
      case 'balanceMatchStatus':
        return balanceMatchStatus;
      case 'status':
        return status;
      case 'durationSec':
        return durationSec.toString();
      case 'errorText':
        return errorText;
      case 'stepSummary':
        return stepSummary;
      default:
        return '';
    }
  }
}
