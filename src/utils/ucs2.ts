/**
 * Кодирует строку UTF-16 в формат UCS2 Hex (big-endian),
 * используемый модемом Huawei E173 для кириллических SMS и USSD.
 */
export function encodeUcs2Hex(input: string): string {
  let hex = '';
  for (let i = 0; i < input.length; i++) {
    const codeUnit = input.charCodeAt(i);
    hex += codeUnit.toString(16).toUpperCase().padStart(4, '0');
  }
  return hex;
}

/**
 * Декодирует строку UCS2 Hex обратно в читаемый текст (включая кириллицу).
 */
export function decodeUcs2Hex(hex: string): string {
  const clean = hex.replace(/[^0-9A-Fa-f]/g, '');
  if (clean.length === 0 || clean.length % 4 !== 0) {
    return hex;
  }
  let out = '';
  for (let i = 0; i < clean.length; i += 4) {
    const code = parseInt(clean.slice(i, i + 4), 16);
    out += String.fromCharCode(code);
  }
  return out;
}

/**
 * Переводит RSSI (0..31) из ответа AT+CSQ в уровень сигнала dBm.
 */
export function csqToDbm(rssi: number): number | null {
  if (rssi === 99 || rssi < 0 || rssi > 31) return null;
  return -113 + rssi * 2;
}

export function csqToPercent(rssi: number): number {
  if (rssi === 99 || rssi < 0) return 0;
  return Math.min(100, Math.round((rssi / 31) * 100));
}

export function csqToBars(rssi: number): number {
  if (rssi === 99 || rssi <= 1) return 0;
  if (rssi <= 7) return 1;
  if (rssi <= 13) return 2;
  if (rssi <= 19) return 3;
  if (rssi <= 25) return 4;
  return 5;
}
