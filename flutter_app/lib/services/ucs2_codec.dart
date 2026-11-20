/// Кодировщик/декодировщик UCS2 Hex для кириллических SMS и USSD модема Huawei E173.
class Ucs2Codec {
  static String encodeHex(String text) {
    final buffer = StringBuffer();
    for (final unit in text.codeUnits) {
      buffer.write(unit.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
    return buffer.toString();
  }

  static String decodeHex(String input) {
    final clean = input.trim().replaceAll('"', '');
    final isHex = RegExp(r'^[0-9A-Fa-f]+$').hasMatch(clean);
    if (!isHex || clean.length < 4 || clean.length % 4 != 0) {
      return clean;
    }
    final units = <int>[];
    for (var i = 0; i < clean.length; i += 4) {
      units.add(int.parse(clean.substring(i, i + 4), radix: 16));
    }
    return String.fromCharCodes(units);
  }

  /// Попытка декодировать ответ USSD (UCS2 Hex или обычный ASCII/GSM текст).
  static String decodeSmart(String raw) {
    final trimmed = raw.trim().replaceAll('"', '');
    if (trimmed.isEmpty) return '';
    final hexOnly = RegExp(r'^[0-9A-Fa-f]+$').hasMatch(trimmed);
    if (hexOnly && trimmed.length % 4 == 0) {
      final decoded = decodeHex(trimmed);
      if (decoded.trim().isNotEmpty) return decoded;
    }
    return trimmed;
  }
}
