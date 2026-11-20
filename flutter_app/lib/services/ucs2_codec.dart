/// Кодировщик/декодировщик UCS2 Hex, GSM 7-bit Packed PDU и парсер баланса/номера из USSD/SMS.
class Ucs2Codec {
  static const String _gsm7Basic =
      '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1BÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';

  static String gsm7CharAt(int code) =>
      (code >= 0 && code < _gsm7Basic.length) ? _gsm7Basic[code] : '?';

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

  /// Кодирует USSD строку (например *100#) в GSM 7-bit Packed Hex (AA180C3602).
  static String encodeGsm7PackedHex(String text) {
    final septets = <int>[];
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final idx = _gsm7Basic.indexOf(ch);
      septets.add(idx >= 0 ? idx : 0x3F);
    }
    if (septets.isEmpty) return '';

    final octets = <int>[];
    var i = 0;
    while (i < septets.length) {
      final shift = i % 8;
      if (shift == 7) {
        i++;
        continue;
      }
      final current = (septets[i] >> shift) & 0x7F;
      final next = (i + 1 < septets.length) ? septets[i + 1] : 0;
      final mask = (1 << (shift + 1)) - 1;
      final high = (next & mask) << (7 - shift);
      octets.add((current | high) & 0xFF);
      i++;
    }

    final buf = StringBuffer();
    for (final b in octets) {
      buf.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return buf.toString();
  }

  static String decodeGsm7PackedHex(String hex) {
    final clean = hex.trim().replaceAll('"', '');
    if (clean.isEmpty ||
        clean.length % 2 != 0 ||
        !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(clean)) {
      return clean;
    }
    final bytes = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }

    final out = StringBuffer();
    var carry = 0;
    var carryBits = 0;

    for (final b in bytes) {
      final septet = ((b << carryBits) | carry) & 0x7F;
      out.write(gsm7CharAt(septet));
      carry = b >> (7 - carryBits);
      carryBits += 1;
      if (carryBits == 7) {
        out.write(gsm7CharAt(carry));
        carry = 0;
        carryBits = 0;
      }
    }
    return out.toString().replaceAll('\r', '').trimRight();
  }

  static String decodeUssdPayload(String raw, int? dcs) {
    final trimmed = raw.trim().replaceAll('"', '');
    if (trimmed.isEmpty) return '';

    final isHex = RegExp(r'^[0-9A-Fa-f]+$').hasMatch(trimmed);

    if (isHex &&
        trimmed.length % 4 == 0 &&
        (dcs == 72 || dcs == 8 || dcs == 24 || _looksLikeUcs2Hex(trimmed))) {
      return decodeHex(trimmed);
    }

    if (isHex &&
        trimmed.length % 2 == 0 &&
        (dcs == 15 || dcs == 0 || dcs == null)) {
      final unpacked = decodeGsm7PackedHex(trimmed);
      if (unpacked.isNotEmpty) return unpacked;
    }

    return trimmed;
  }

  static bool _looksLikeUcs2Hex(String hex) {
    if (hex.length < 8 || hex.length % 4 != 0) return false;
    var printable = 0;
    final total = hex.length ~/ 4;
    for (var i = 0; i < hex.length; i += 4) {
      final unit = int.parse(hex.substring(i, i + 4), radix: 16);
      if ((unit >= 0x0020 && unit <= 0x007E) ||
          (unit >= 0x0400 && unit <= 0x04FF) ||
          unit == 0x000A ||
          unit == 0x000D) {
        printable++;
      }
    }
    return printable / total >= 0.8;
  }

  static String decodeSmart(String raw) {
    final trimmed = raw.trim().replaceAll('"', '');
    if (trimmed.isEmpty) return '';
    final hexOnly = RegExp(r'^[0-9A-Fa-f]+$').hasMatch(trimmed);
    if (hexOnly && trimmed.length % 4 == 0 && _looksLikeUcs2Hex(trimmed)) {
      final decoded = decodeHex(trimmed);
      if (decoded.trim().isNotEmpty) return decoded;
    }
    return trimmed;
  }

  /// Раздельный разбор номера телефона и суммы баланса из комбинированного USSD/SMS ответа.
  static String? extractPhoneNumber(String text) {
    final re = RegExp(r'(\+?\d[\d\-\s\(\)]{8,15}\d)');
    for (final m in re.allMatches(text)) {
      final digits = m.group(1)!.replaceAll(RegExp(r'\D'), '');
      if (digits.length == 11 && (digits.startsWith('7') || digits.startsWith('8'))) {
        return '+7${digits.substring(1)}';
      }
      if (digits.length == 10 && digits.startsWith('9')) {
        return '+7$digits';
      }
      if (digits.length >= 10 && digits.length <= 13) {
        return '+$digits';
      }
    }
    return null;
  }

  /// Извлекает сумму баланса (игнорируя номера телефонов) из текста USSD/SMS.
  static double? extractBalance(String text) {
    // Сначала убираем возможные номера телефонов, чтобы не спутать их с суммой
    final cleaned = text.replaceAll(RegExp(r'\+?[78][\d\-\s\(\)]{9,14}'), ' ');

    // Приоритет 1: число рядом со словом баланс / руб / р. / rub / ₽
    final patterns = [
      RegExp(
        r'(?:баланс|balance|остаток|счет|счёт)[^\d\-]{0,20}(-?\d+(?:[.,]\d{1,2})?)',
        caseSensitive: false,
      ),
      RegExp(
        r'(-?\d+(?:[.,]\d{1,2})?)\s*(?:руб|р\.|rub|₽)',
        caseSensitive: false,
      ),
      RegExp(r'(-?\d+[.,]\d{1,2})'),
    ];

    for (final p in patterns) {
      final m = p.firstMatch(cleaned);
      if (m != null) {
        final rawNum = m.group(1)!.replaceAll(',', '.');
        final val = double.tryParse(rawNum);
        if (val != null) return val;
      }
    }
    return null;
  }
}
