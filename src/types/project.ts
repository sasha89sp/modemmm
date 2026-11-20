export interface UssdShortcut {
  id: string;
  label: string;
  code: string;
}

export interface OperatorPreset {
  id: string;
  name: string;
  apn: string;
  dialNumber: string;
  username: string;
  password: string;
  balanceUssd: string;
  numberUssd: string;
}

export interface ProjectConfig {
  appTitle: string;
  packageName: string;
  version: string;
  defaultBaudRate: number;
  autoConnectPort: boolean;
  defaultOperatorId: string;
  customApn: string;
  customDialNumber: string;
  enableRasDialer: boolean;
  enableU2DiagTools: boolean;
  portableConfigNextToExe: boolean;
  githubReleaseOnTag: boolean;
  githubIncludeSfxBatch: boolean;
  ussdShortcuts: UssdShortcut[];
}

export interface GeneratedFile {
  path: string;
  language: 'dart' | 'yaml' | 'markdown' | 'text' | 'batch';
  description: string;
  content: string;
}

export interface SimulatedSms {
  id: number;
  direction: 'in' | 'out';
  phone: string;
  text: string;
  timestamp: string;
  unread: boolean;
  ucs2Hex: string;
}

export interface AtLogEntry {
  id: string;
  time: string;
  direction: 'tx' | 'rx' | 'info';
  text: string;
}

export type NetworkMode = 'auto' | '3g_only' | '2g_only' | '3g_pref';

export type U2DiagMode = 0 | 255 | 256;

export interface ComPortInfo {
  port: string;
  friendlyName: string;
  vidPid: string;
  isRecommended: boolean;
}
