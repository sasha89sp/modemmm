import 'dart:io';
import 'portable_config.dart';

/// Управление Dial-Up соединением Windows через встроенную утилиту rasdial.exe
/// с портативной телефонной книгой huawei_e173.pbk рядом с .exe.
class RasDialer {
  static const String entryName = 'Huawei_E173_Portable';

  static File get phonebookFile => File(
        '${PortableConfig.baseDirectory}${Platform.pathSeparator}huawei_e173.pbk',
      );

  static Future<void> ensurePhonebook({
    required String dialNumber,
  }) async {
    final content = '''[$entryName]
Encoding=1
Type=1
AutoLogon=0
UseRasCredentials=0
DialParamsUID=1001
BaseProtocol=1
VpnStrategy=0
ExcludedProtocols=0
LcpExtensions=1
DataEncryption=8
SwCompression=1
NegotiateMultilinkAlways=0
SkipNwcWarning=0
SkipDownLevelDialog=0
SkipDoubleDialDialog=0
DialMode=1
DialPercent=75
DialSeconds=120
HangUpPercent=10
HangUpSeconds=120
OverridePref=15
RedialAttempts=3
RedialSeconds=5
IdleDisconnectSeconds=0
RedialOnLinkFailure=1
PopupOnTopWhenRedialing=1
MEDIA=serial
Port=MODEM
Device=HUAWEI Mobile Connect - 3G Modem
PhoneNumber=$dialNumber
''';
    await phonebookFile.writeAsString(content);
  }

  static Future<String> connect({
    required String dialNumber,
    String username = '',
    String password = '',
  }) async {
    await ensurePhonebook(dialNumber: dialNumber);
    final args = <String>[
      entryName,
      if (username.isNotEmpty) username,
      if (password.isNotEmpty) password,
      '/PHONEBOOK:${phonebookFile.path}',
    ];
    final res = await Process.run('rasdial', args);
    final out = '${res.stdout}${res.stderr}'.trim();
    return out.isEmpty ? 'Команда подключения отправлена.' : out;
  }

  static Future<String> disconnect() async {
    final res = await Process.run('rasdial', [entryName, '/DISCONNECT']);
    final out = '${res.stdout}${res.stderr}'.trim();
    return out.isEmpty ? 'Соединение разорвано.' : out;
  }
}
