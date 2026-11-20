import { ComPortInfo, OperatorPreset, ProjectConfig, SimulatedSms } from '../types/project';

export const OPERATOR_PRESETS: OperatorPreset[] = [
  {
    id: 'mts',
    name: 'МТС',
    apn: 'internet.mts.ru',
    dialNumber: '*99#',
    username: 'mts',
    password: 'mts',
    balanceUssd: '*100#',
    numberUssd: '*111*0887#',
  },
  {
    id: 'megafon',
    name: 'МегаФон',
    apn: 'internet',
    dialNumber: '*99#',
    username: '',
    password: '',
    balanceUssd: '*100#',
    numberUssd: '*205#',
  },
  {
    id: 'beeline',
    name: 'Билайн',
    apn: 'internet.beeline.ru',
    dialNumber: '*99#',
    username: 'beeline',
    password: 'beeline',
    balanceUssd: '*102#',
    numberUssd: '*110*10#',
  },
  {
    id: 'tele2',
    name: 'T2 (Tele2)',
    apn: 'internet.tele2.ru',
    dialNumber: '*99#',
    username: '',
    password: '',
    balanceUssd: '*105#',
    numberUssd: '*201#',
  },
  {
    id: 'yota',
    name: 'Yota',
    apn: 'internet.yota',
    dialNumber: '*99#',
    username: '',
    password: '',
    balanceUssd: '*100#',
    numberUssd: '*103#',
  },
  {
    id: 'custom',
    name: 'Свой APN',
    apn: 'internet',
    dialNumber: '*99#',
    username: '',
    password: '',
    balanceUssd: '*100#',
    numberUssd: '*102#',
  },
];

export const DEFAULT_PROJECT_CONFIG: ProjectConfig = {
  appTitle: 'Huawei E173 Portable Manager',
  packageName: 'huawei_e173_manager',
  version: '1.0.0+1',
  defaultBaudRate: 115200,
  autoConnectPort: true,
  defaultOperatorId: 'megafon',
  customApn: 'internet',
  customDialNumber: '*99#',
  enableRasDialer: true,
  enableU2DiagTools: true,
  portableConfigNextToExe: true,
  githubReleaseOnTag: true,
  githubIncludeSfxBatch: true,
  ussdShortcuts: [
    { id: 'u1', label: 'Баланс', code: '*100#' },
    { id: 'u2', label: 'Баланс (Билайн)', code: '*102#' },
    { id: 'u3', label: 'Остаток трафика', code: '*105#' },
    { id: 'u4', label: 'Мой номер', code: '*205#' },
  ],
};

export const SIMULATED_PORTS: ComPortInfo[] = [
  {
    port: 'COM5',
    friendlyName: 'HUAWEI Mobile Connect - 3G PC UI Interface',
    vidPid: 'USB\\VID_12D1&PID_1436&MI_02',
    isRecommended: true,
  },
  {
    port: 'COM4',
    friendlyName: 'HUAWEI Mobile Connect - 3G Application Interface',
    vidPid: 'USB\\VID_12D1&PID_1436&MI_01',
    isRecommended: false,
  },
  {
    port: 'COM3',
    friendlyName: 'HUAWEI Mobile Connect - 3G Modem',
    vidPid: 'USB\\VID_12D1&PID_1436&MI_00',
    isRecommended: false,
  },
  {
    port: 'COM1',
    friendlyName: 'Последовательный порт (COM1)',
    vidPid: 'ACPI\\PNP0501',
    isRecommended: false,
  },
];

export const INITIAL_SMS_LIST: SimulatedSms[] = [
  {
    id: 1,
    direction: 'in',
    phone: 'MegaFon',
    text: 'Баланс: 342.50 руб. Остаток пакета интернета: 14.8 ГБ до 01.12.2026.',
    timestamp: '20.11.2026 09:42',
    unread: true,
    ucs2Hex: '04110430043B0430043D0441003A0020003300340032002E00350030',
  },
  {
    id: 2,
    direction: 'in',
    phone: '+79261234567',
    text: 'Датчик на объекте №2 переведён на резервный канал 3G.',
    timestamp: '19.11.2026 18:15',
    unread: false,
    ucs2Hex: '04140430044204470438043A0020043D04300020043E0431044A0435043A04420435',
  },
  {
    id: 3,
    direction: 'out',
    phone: '+79261234567',
    text: 'Принято, сигнал -73 dBm, модем E173 в режиме только 3G.',
    timestamp: '19.11.2026 18:19',
    unread: false,
    ucs2Hex: '041F04400438043D044F0442043E002C0020044104380433043D0430043B',
  },
];

export const AT_QUICK_COMMANDS = [
  { cmd: 'ATI', desc: 'Модель, прошивка, IMEI' },
  { cmd: 'AT+CSQ', desc: 'Уровень сигнала (RSSI)' },
  { cmd: 'AT+COPS?', desc: 'Текущий оператор связи' },
  { cmd: 'AT^SYSINFO', desc: 'Режим сети (2G/3G/HSPA)' },
  { cmd: 'AT+CPIN?', desc: 'Статус SIM-карты' },
  { cmd: 'AT^U2DIAG?', desc: 'Текущий USB-режим E173' },
  { cmd: 'AT^CARDLOCK?', desc: 'Статус блокировки и попытки NCK' },
  { cmd: 'AT+CGDCONT?', desc: 'Профили APN для интернета' },
  { cmd: 'AT+CFUN=1,1', desc: 'Мягкая перезагрузка модема' },
];

export const U2DIAG_MODES = [
  {
    value: 0 as const,
    code: 'AT^U2DIAG=0',
    title: 'Только модем',
    summary: 'Отключает виртуальный CD-ROM и MicroSD. Идеально для роутеров и быстрой инициализации COM-портов в Windows.',
  },
  {
    value: 256 as const,
    code: 'AT^U2DIAG=256',
    title: 'Модем + Кардридер MicroSD',
    summary: 'Отключает CD-ROM с автозапуском, но оставляет доступ к карте памяти MicroSD в модеме.',
  },
  {
    value: 255 as const,
    code: 'AT^U2DIAG=255',
    title: 'Заводской режим (Модем + CD + SD)',
    summary: 'Возвращает стандартную конфигурацию Huawei E173 со встроенным диском драйверов.',
  },
];

export const SYSCFG_MODES = [
  {
    value: 'auto' as const,
    code: 'AT^SYSCFG=2,2,3FFFFFFF,1,2',
    label: 'Авто (2G / 3G)',
    tech: 'HSPA+ / EDGE',
  },
  {
    value: '3g_only' as const,
    code: 'AT^SYSCFG=14,2,3FFFFFFF,1,2',
    label: 'Только 3G (WCDMA)',
    tech: 'WCDMA / HSDPA',
  },
  {
    value: '3g_pref' as const,
    code: 'AT^SYSCFG=2,2,3FFFFFFF,1,2',
    label: 'Приоритет 3G',
    tech: 'WCDMA → GSM',
  },
  {
    value: '2g_only' as const,
    code: 'AT^SYSCFG=13,1,3FFFFFFF,1,2',
    label: 'Только 2G (GSM/EDGE)',
    tech: 'GSM / EDGE',
  },
];
