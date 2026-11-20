import 'ucs2_codec.dart';

class DecodedPduSms {
  final int modemIndex;
  final int stat; // 0=unread, 1=read, 2=unsent, 3=sent
  final String address;
  final String timestamp;
  final String text;
  final int? concatRef;
  final int concatTotal;
  final int concatSeq;

  const DecodedPduSms({
    required this.modemIndex,
    required this.stat,
    required this.address,
    required this.timestamp,
    required this.text,
    this.concatRef,
    this.concatTotal = 1,
    this.concatSeq = 1,
  });

  bool get isSent => stat == 2 || stat == 3;
}

class AssembledSms {
  final List<int> modemIndices;
  final String folder; // 'inbox' | 'sent'
  final String address;
  final String timestamp;
  final String body;
  final bool isRead;

  const AssembledSms({
    required this.modemIndices,
    required this.folder,
    required this.address,
    required this.timestamp,
    required this.body,
    required this.isRead,
  });
}

/// Полноценный декодер GSM 03.40 SMS-DELIVER / SMS-SUBMIT PDU
/// с поддержкой UCS-2 (кириллица), GSM 7-bit, 8-bit и склейки составных сообщений (UDH).
class PduCodec {
  static DecodedPduSms? decodePdu({
    required int modemIndex,
    required int stat,
    required String pduHex,
  }) {
    final hex = pduHex.trim().toUpperCase();
    if (hex.length < 16 || hex.length % 2 != 0) return null;

    try {
      var pos = 0;
      int readByte() {
        final v = int.parse(hex.substring(pos, pos + 2), radix: 16);
        pos += 2;
        return v;
      }

      // 1. SMSC length & skip SMSC
      final smscLen = readByte();
      pos += smscLen * 2;
      if (pos >= hex.length) return null;

      // 2. First octet (PDU Type)
      final firstOctet = readByte();
      final mti = firstOctet & 0x03; // 0 = SMS-DELIVER, 1 = SMS-SUBMIT
      final hasUdhi = (firstOctet & 0x40) != 0;

      if (mti == 1) {
        // SMS-SUBMIT: skip TP-MR (Message Reference)
        readByte();
      }

      // 3. Originating / Destination Address
      final addrLen = readByte(); // number of semi-octets (digits)
      final addrType = readByte();
      final addrByteCount = (addrLen + 1) ~/ 2;
      final addrHex = hex.substring(pos, pos + addrByteCount * 2);
      pos += addrByteCount * 2;
      final address = _decodeAddress(addrHex, addrType, addrLen);

      // 4. PID & DCS
      readByte(); // TP-PID
      final dcs = readByte();

      // 5. Timestamp (SMS-DELIVER) or VP (SMS-SUBMIT)
      var timestamp = '';
      if (mti == 0) {
        final sctsHex = hex.substring(pos, pos + 14);
        pos += 14;
        timestamp = _decodeScts(sctsHex);
      } else {
        final vpf = (firstOctet >> 3) & 0x03;
        if (vpf == 2) {
          pos += 2; // relative VP (1 byte)
        } else if (vpf == 1 || vpf == 3) {
          pos += 14; // enhanced / absolute VP (7 bytes)
        }
      }

      // 6. User Data Length & User Data
      if (pos >= hex.length) return null;
      final udl = readByte();
      final udHex = hex.substring(pos);
      final udBytes = <int>[];
      for (var i = 0; i + 1 < udHex.length; i += 2) {
        udBytes.add(int.parse(udHex.substring(i, i + 2), radix: 16));
      }

      int? concatRef;
      int concatTotal = 1;
      int concatSeq = 1;
      var udhByteLen = 0;

      if (hasUdhi && udBytes.isNotEmpty) {
        final udhl = udBytes[0];
        udhByteLen = udhl + 1;
        var u = 1;
        while (u + 1 < udhByteLen && u + 1 < udBytes.length) {
          final iei = udBytes[u];
          final iedl = udBytes[u + 1];
          if (iei == 0x00 && iedl == 3 && u + 4 < udBytes.length) {
            concatRef = udBytes[u + 2];
            concatTotal = udBytes[u + 3];
            concatSeq = udBytes[u + 4];
          } else if (iei == 0x08 && iedl == 4 && u + 5 < udBytes.length) {
            concatRef = (udBytes[u + 2] << 8) | udBytes[u + 3];
            concatTotal = udBytes[u + 4];
            concatSeq = udBytes[u + 5];
          }
          u += 2 + iedl;
        }
      }

      final coding = (dcs >> 2) & 0x03;
      String text;
      if (coding == 2) {
        // UCS-2 (UTF-16BE)
        final payloadBytes =
            udhByteLen < udBytes.length ? udBytes.sublist(udhByteLen) : <int>[];
        final units = <int>[];
        for (var i = 0; i + 1 < payloadBytes.length; i += 2) {
          units.add((payloadBytes[i] << 8) | payloadBytes[i + 1]);
        }
        text = String.fromCharCodes(units);
      } else if (coding == 1) {
        // 8-bit data
        final payloadBytes =
            udhByteLen < udBytes.length ? udBytes.sublist(udhByteLen) : <int>[];
        text = String.fromCharCodes(payloadBytes);
      } else {
        // GSM 7-bit packed (with UDH septet padding alignment)
        final skipSeptets =
            udhByteLen > 0 ? ((udhByteLen * 8) + 6) ~/ 7 : 0;
        text = _decodeGsm7FromBytes(udBytes, udl, skipSeptets);
      }

      return DecodedPduSms(
        modemIndex: modemIndex,
        stat: stat,
        address: address,
        timestamp: timestamp,
        text: text,
        concatRef: concatRef,
        concatTotal: concatTotal,
        concatSeq: concatSeq,
      );
    } catch (_) {
      return null;
    }
  }

  /// Склеивает составные (многочастные) SMS по concatRef + address.
  static List<AssembledSms> assembleParts(List<DecodedPduSms> parts) {
    final result = <AssembledSms>[];
    final grouped = <String, List<DecodedPduSms>>{};

    for (final p in parts) {
      if (p.concatRef != null && p.concatTotal > 1) {
        final key = '${p.address}|${p.concatRef}|${p.concatTotal}|${p.isSent}';
        grouped.putIfAbsent(key, () => []).add(p);
      } else {
        result.add(AssembledSms(
          modemIndices: [p.modemIndex],
          folder: p.isSent ? 'sent' : 'inbox',
          address: p.address,
          timestamp: p.timestamp,
          body: p.text,
          isRead: p.stat != 0,
        ));
      }
    }

    for (final entry in grouped.values) {
      entry.sort((a, b) => a.concatSeq.compareTo(b.concatSeq));
      final joined = entry.map((e) => e.text).join();
      final first = entry.first;
      result.add(AssembledSms(
        modemIndices: entry.map((e) => e.modemIndex).toList(),
        folder: first.isSent ? 'sent' : 'inbox',
        address: first.address,
        timestamp: first.timestamp,
        body: joined,
        isRead: entry.every((e) => e.stat != 0),
      ));
    }

    return result;
  }

  static String _decodeAddress(String addrHex, int addrType, int addrLen) {
    final ton = (addrType >> 4) & 0x07;
    if (ton == 5) {
      // Alphanumeric (GSM 7-bit packed)
      final septetCount = (addrLen * 4) ~/ 7;
      final bytes = <int>[];
      for (var i = 0; i + 1 < addrHex.length; i += 2) {
        bytes.add(int.parse(addrHex.substring(i, i + 2), radix: 16));
      }
      return _decodeGsm7FromBytes(bytes, septetCount, 0);
    }
    final digits = StringBuffer();
    if (ton == 1) digits.write('+');
    for (var i = 0; i + 1 < addrHex.length; i += 2) {
      final low = addrHex[i + 1];
      final high = addrHex[i];
      if (low != 'F') digits.write(low);
      if (high != 'F') digits.write(high);
    }
    return digits.toString();
  }

  static String _decodeScts(String sctsHex) {
    if (sctsHex.length < 12) return '';
    String swap(int offset) => '${sctsHex[offset + 1]}${sctsHex[offset]}';
    final yy = swap(0);
    final mm = swap(2);
    final dd = swap(4);
    final hh = swap(6);
    final mi = swap(8);
    final ss = swap(10);
    return '20$yy-$mm-$dd $hh:$mi:$ss';
  }

  static String _decodeGsm7FromBytes(
    List<int> bytes,
    int totalSeptets,
    int skipSeptets,
  ) {
    final septets = <int>[];
    var carry = 0;
    var carryBits = 0;

    for (final b in bytes) {
      final s = ((b << carryBits) | carry) & 0x7F;
      septets.add(s);
      carry = b >> (7 - carryBits);
      carryBits += 1;
      if (carryBits == 7) {
        septets.add(carry & 0x7F);
        carry = 0;
        carryBits = 0;
      }
    }

    final limit =
        totalSeptets > 0 && totalSeptets <= septets.length ? totalSeptets : septets.length;
    final out = StringBuffer();
    for (var i = skipSeptets; i < limit; i++) {
      out.write(Ucs2Codec.gsm7CharAt(septets[i]));
    }
    return out.toString();
  }
}
