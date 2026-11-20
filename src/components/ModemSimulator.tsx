import React, { useEffect, useMemo, useState } from 'react';
import {
  Antenna,
  ArrowDownUp,
  Check,
  MessageSquare,
  Phone,
  Power,
  RefreshCw,
  Send,
  Settings2,
  Signal,
  Terminal,
  Trash2,
  Usb,
  Wifi,
} from 'lucide-react';
import {
  AT_QUICK_COMMANDS,
  INITIAL_SMS_LIST,
  OPERATOR_PRESETS,
  SIMULATED_PORTS,
  SYSCFG_MODES,
  U2DIAG_MODES,
} from '../data/presets';
import {
  AtLogEntry,
  NetworkMode,
  ProjectConfig,
  SimulatedSms,
  U2DiagMode,
} from '../types/project';
import { csqToBars, csqToDbm, csqToPercent, encodeUcs2Hex } from '../utils/ucs2';

interface ModemSimulatorProps {
  config: ProjectConfig;
}

type SimTab = 'overview' | 'sms' | 'ussd' | 'modes' | 'terminal';

function nowTime(): string {
  const d = new Date();
  return d.toLocaleTimeString('ru-RU', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
}

export const ModemSimulator: React.FC<ModemSimulatorProps> = ({ config }) => {
  const activePreset = useMemo(
    () =>
      OPERATOR_PRESETS.find((p) => p.id === config.defaultOperatorId) ||
      OPERATOR_PRESETS[0],
    [config.defaultOperatorId]
  );

  const [tab, setTab] = useState<SimTab>('overview');
  const [selectedPort, setSelectedPort] = useState<string>('COM5');
  const [connected, setConnected] = useState<boolean>(true);
  const [scanning, setScanning] = useState<boolean>(false);

  // Modem hardware telemetry
  const [rssi, setRssi] = useState<number>(20);
  const [networkMode, setNetworkMode] = useState<NetworkMode>('3g_only');
  const [u2diagMode, setU2diagMode] = useState<U2DiagMode>(0);
  const [cardUnlocked, setCardUnlocked] = useState<boolean>(true);
  const [apn, setApn] = useState<string>(
    config.defaultOperatorId === 'custom' ? config.customApn : activePreset.apn
  );
  const [rasConnected, setRasConnected] = useState<boolean>(false);
  const [rasSeconds, setRasSeconds] = useState<number>(0);
  const [rxKb, setRxKb] = useState<number>(0);
  const [txKb, setTxKb] = useState<number>(0);

  // SMS state
  const [smsList, setSmsList] = useState<SimulatedSms[]>(INITIAL_SMS_LIST);
  const [smsSearch, setSmsSearch] = useState<string>('');
  const [smsPhone, setSmsPhone] = useState<string>('+79261234567');
  const [smsText, setSmsText] = useState<string>('');

  // USSD state
  const [ussdInput, setUssdInput] = useState<string>(
    config.ussdShortcuts[0]?.code || '*100#'
  );
  const [ussdResult, setUssdResult] = useState<{
    code: string;
    decoded: string;
    rawHex: string;
    time: string;
  } | null>({
    code: '*100#',
    decoded: 'Баланс: 342.50 руб. Тариф: Интернет для устройств. Остаток: 14.8 ГБ.',
    rawHex: encodeUcs2Hex('Баланс: 342.50 руб.'),
    time: '09:45:12',
  });

  // NCK & Modes state
  const [nckInput, setNckInput] = useState<string>('');
  const [statusNotice, setStatusNotice] = useState<string>('');

  // AT terminal state
  const [atInput, setAtInput] = useState<string>('ATI');
  const [atLogs, setAtLogs] = useState<AtLogEntry[]>([
    {
      id: 'init-1',
      time: '09:44:01',
      direction: 'info',
      text: 'Win32 CreateFileW("\\\\.\\COM5") успешно открыт · 115200 8N1 (DTR/RTS=ON)',
    },
    { id: 'init-2', time: '09:44:01', direction: 'tx', text: 'ATI' },
    {
      id: 'init-3',
      time: '09:44:01',
      direction: 'rx',
      text: 'Manufacturer: huawei | Model: E173 | Revision: 11.126.85.00.209 | IMEI: 358941042187349 | OK',
    },
    { id: 'init-4', time: '09:44:02', direction: 'tx', text: 'AT+CSQ' },
    { id: 'init-5', time: '09:44:02', direction: 'rx', text: '+CSQ: 20,99 · OK' },
  ]);

  // Sync APN when user changes preset in Configurator
  useEffect(() => {
    setApn(
      config.defaultOperatorId === 'custom' ? config.customApn : activePreset.apn
    );
  }, [config.defaultOperatorId, config.customApn, activePreset.apn]);

  // Simulated RAS session counter
  useEffect(() => {
    if (!rasConnected || !connected) return;
    const timer = window.setInterval(() => {
      setRasSeconds((s) => s + 1);
      setRxKb((k) => k + Math.floor(18 + Math.random() * 44));
      setTxKb((k) => k + Math.floor(4 + Math.random() * 14));
    }, 1000);
    return () => window.clearInterval(timer);
  }, [rasConnected, connected]);

  const appendLog = (direction: 'tx' | 'rx' | 'info', text: string) => {
    setAtLogs((prev) => [
      {
        id: `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
        time: nowTime(),
        direction,
        text,
      },
      ...prev.slice(0, 120),
    ]);
  };

  const notify = (message: string) => {
    setStatusNotice(message);
    window.setTimeout(() => {
      setStatusNotice((curr) => (curr === message ? '' : curr));
    }, 3600);
  };

  const handleScanPorts = () => {
    setScanning(true);
    window.setTimeout(() => {
      setScanning(false);
      appendLog(
        'info',
        'Win32 PnP сканер: найдено 4 порта · выделен COM5 (VID_12D1&PID_1436 PC UI Interface)'
      );
      notify('Найдено 4 COM-порта. Порт COM5 определён как Huawei E173 PC UI.');
    }, 350);
  };

  const handleToggleConnect = () => {
    if (connected) {
      setConnected(false);
      setRasConnected(false);
      appendLog('info', `CloseHandle(${selectedPort}) — соединение с портом закрыто`);
      notify(`Порт ${selectedPort} отключён.`);
    } else {
      setConnected(true);
      appendLog(
        'info',
        `CreateFileW("\\\\.\\${selectedPort}") открыт (${config.defaultBaudRate} бод, 8N1)`
      );
      appendLog('tx', 'ATE0');
      appendLog('rx', 'OK');
      notify(`Подключено к ${selectedPort}. Модем Huawei E173 отвечает.`);
    }
  };

  const executeAtCommand = (rawCmd: string) => {
    const cmd = rawCmd.trim();
    if (!cmd) return;
    if (!connected) {
      notify('Сначала откройте COM-порт модема.');
      return;
    }

    appendLog('tx', cmd);
    const upper = cmd.toUpperCase();

    if (upper === 'AT' || upper === 'ATE0' || upper === 'AT+CMEE=2') {
      appendLog('rx', 'OK');
      return;
    }
    if (upper === 'ATI') {
      appendLog(
        'rx',
        'Manufacturer: huawei | Model: E173 | Revision: 11.126.85.00.209 | IMEI: 358941042187349 | +GCAP: +CGSM,+DS,+ES | OK'
      );
      return;
    }
    if (upper === 'AT+CSQ') {
      appendLog('rx', `+CSQ: ${rssi},99 · OK`);
      return;
    }
    if (upper === 'AT+COPS?') {
      appendLog('rx', `+COPS: 0,0,"${activePreset.name}",2 · OK`);
      return;
    }
    if (upper === 'AT+CPIN?') {
      appendLog('rx', '+CPIN: READY · OK');
      return;
    }
    if (upper === 'AT+CIMI') {
      appendLog('rx', '250027481920451 · OK');
      return;
    }
    if (upper === 'AT^SYSINFO') {
      const sysMode = networkMode === '2g_only' ? 3 : 5;
      const subMode = networkMode === '2g_only' ? 3 : 7;
      appendLog('rx', `^SYSINFO:2,3,0,${sysMode},1,,${subMode} · OK`);
      return;
    }
    if (upper === 'AT^U2DIAG?') {
      appendLog('rx', `${u2diagMode} · OK`);
      return;
    }
    if (upper.startsWith('AT^U2DIAG=')) {
      const val = parseInt(upper.replace('AT^U2DIAG=', ''), 10);
      if (val === 0 || val === 255 || val === 256) {
        setU2diagMode(val);
        appendLog('rx', 'OK');
        notify(`Применён режим AT^U2DIAG=${val}. Изменения вступят после переподключения USB.`);
      } else {
        appendLog('rx', 'ERROR (допустимы 0, 255, 256 для E173)');
      }
      return;
    }
    if (upper === 'AT^CARDLOCK?') {
      appendLog('rx', cardUnlocked ? '^CARDLOCK: 2,10,0 · OK' : '^CARDLOCK: 1,7,0 · OK');
      return;
    }
    if (upper === 'AT+CGDCONT?') {
      appendLog('rx', `+CGDCONT: 1,"IP","${apn}","0.0.0.0",0,0 · OK`);
      return;
    }
    if (upper.startsWith('AT+CGDCONT=')) {
      appendLog('rx', 'OK');
      return;
    }
    if (upper === 'AT+CFUN=1,1') {
      appendLog('rx', 'OK (модем перезагружается...)');
      setRasConnected(false);
      notify('Команда перезагрузки AT+CFUN=1,1 отправлена модему.');
      return;
    }
    appendLog('rx', 'OK');
  };

  const handleSendSms = (e: React.FormEvent) => {
    e.preventDefault();
    if (!connected) {
      notify('Подключите COM-порт перед отправкой SMS.');
      return;
    }
    const cleanPhone = smsPhone.trim();
    const cleanBody = smsText.trim();
    if (!cleanPhone || !cleanBody) return;

    const hexPhone = encodeUcs2Hex(cleanPhone);
    const hexBody = encodeUcs2Hex(cleanBody);

    appendLog('tx', 'AT+CMGF=1 · AT+CSCS="UCS2" · AT+CSMP=17,167,0,8');
    appendLog('tx', `AT+CMGS="${hexPhone}" → ${hexBody.slice(0, 36)}... [Ctrl+Z]`);
    appendLog('rx', `+CMGS: ${smsList.length + 14} · OK`);

    const newItem: SimulatedSms = {
      id: Date.now(),
      direction: 'out',
      phone: cleanPhone,
      text: cleanBody,
      timestamp: `Сегодня ${nowTime().slice(0, 5)}`,
      unread: false,
      ucs2Hex: hexBody,
    };
    setSmsList((prev) => [newItem, ...prev]);
    setSmsText('');
    notify(`SMS на номер ${cleanPhone} отправлено в кодировке UCS2.`);
  };

  const handleSendUssd = (code: string) => {
    const clean = code.trim();
    if (!clean) return;
    if (!connected) {
      notify('Подключите COM-порт перед отправкой USSD.');
      return;
    }
    setUssdInput(clean);
    const encoded = encodeUcs2Hex(clean);
    appendLog('tx', `AT+CUSD=1,"${encoded}",15`);

    let replyText = `Ответ оператора ${activePreset.name} на запрос ${clean}: услуга активна.`;
    if (clean === '*100#' || clean === '*102#') {
      replyText = `Баланс: 342.50 руб. (${activePreset.name}). Очередное списание 01.12.2026.`;
    } else if (clean === '*105#') {
      replyText = 'Остаток трафика: 14.8 ГБ из 30 ГБ. Скорость не ограничена.';
    } else if (clean === '*205#' || clean === '*201#' || clean === '*110*10#') {
      replyText = 'Ваш номер: +7 (926) 555-01-73.';
    }

    const replyHex = encodeUcs2Hex(replyText);
    appendLog('rx', `+CUSD: 0,"${replyHex.slice(0, 44)}...",72 · OK`);
    setUssdResult({
      code: clean,
      decoded: replyText,
      rawHex: replyHex,
      time: nowTime(),
    });
  };

  const handleApplySyscfg = (mode: NetworkMode, cmd: string) => {
    if (!connected) {
      notify('Подключите COM-порт для смены режима сети.');
      return;
    }
    setNetworkMode(mode);
    executeAtCommand(cmd);
    notify(`Режим сети изменён (${cmd}).`);
  };

  const handleToggleRas = () => {
    if (!connected) {
      notify('Сначала откройте COM-порт модема.');
      return;
    }
    if (rasConnected) {
      setRasConnected(false);
      appendLog('info', 'rasdial Huawei_E173_Portable /DISCONNECT → Соединение завершено');
      notify('Интернет-соединение Windows RAS разорвано.');
    } else {
      executeAtCommand(`AT+CGDCONT=1,"IP","${apn}"`);
      appendLog(
        'info',
        `rasdial Huawei_E173_Portable /PHONEBOOK:.\\huawei_e173.pbk (${config.customDialNumber}) → Подключено`
      );
      setRasConnected(true);
      setRasSeconds(0);
      setRxKb(0);
      setTxKb(0);
      notify(`Интернет подключён через APN «${apn}».`);
    }
  };

  const dbm = csqToDbm(rssi);
  const signalPct = csqToPercent(rssi);
  const bars = csqToBars(rssi);
  const currentTech =
    networkMode === '2g_only'
      ? '2G EDGE'
      : networkMode === '3g_only'
      ? '3G HSPA+'
      : '3G WCDMA / HSPA';

  const filteredSms = useMemo(() => {
    const q = smsSearch.trim().toLowerCase();
    if (!q) return smsList;
    return smsList.filter(
      (s) =>
        s.phone.toLowerCase().includes(q) || s.text.toLowerCase().includes(q)
    );
  }, [smsList, smsSearch]);

  const formatDuration = (total: number) => {
    const mm = String(Math.floor(total / 60)).padStart(2, '0');
    const ss = String(total % 60).padStart(2, '0');
    return `${mm}:${ss}`;
  };

  return (
    <div className="space-y-6">
      {/* Intro summary */}
      <div className="flex flex-col lg:flex-row lg:items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-slate-900">
            Интерактивный макет: {config.appTitle}
          </h1>
          <p className="mt-1 text-sm text-slate-600 max-w-2xl">
            Проверьте интерфейс будущей портативной Windows-программы на Flutter и протестируйте работу AT-команд Huawei E173 перед скачиванием репозитория для GitHub Actions.
          </p>
        </div>
        <div className="flex items-center gap-2 text-xs text-slate-500 whitespace-nowrap">
          <span>Win32 FFI (kernel32.dll)</span>
          <span aria-hidden="true">·</span>
          <span className="font-mono">{config.defaultBaudRate} бод</span>
          <span aria-hidden="true">·</span>
          <span>Портативный config.json</span>
        </div>
      </div>

      {/* Simulated Windows Desktop Frame */}
      <div className="bg-white border border-slate-200 rounded-xl overflow-hidden">
        {/* Windows Title Bar */}
        <div className="flex items-center justify-between px-4 py-2.5 bg-slate-900 text-slate-100 border-b border-slate-800">
          <div className="flex items-center gap-2.5 min-w-0">
            <Usb className="w-4 h-4 text-blue-400 shrink-0" />
            <span className="text-xs font-medium truncate">
              {config.appTitle} — Windows x64 Portable
            </span>
          </div>
          <div className="flex items-center gap-3 text-xs text-slate-400 font-mono shrink-0">
            <span>{config.packageName}.exe</span>
            <span aria-hidden="true">·</span>
            <span>{connected ? `${selectedPort} открыт` : 'Отключён'}</span>
          </div>
        </div>

        {/* COM-port control toolbar */}
        <div className="flex flex-wrap items-center gap-3 px-5 py-3.5 bg-slate-50/70 border-b border-slate-200">
          <div className="flex-1 min-w-[260px]">
            <label htmlFor="com-port-select" className="sr-only">
              COM-порт модема Huawei E173
            </label>
            <select
              id="com-port-select"
              value={selectedPort}
              disabled={connected}
              onChange={(e) => setSelectedPort(e.target.value)}
              className="w-full h-10 px-3 text-sm bg-white border border-slate-300 rounded-lg text-slate-900 focus:outline-none focus:ring-2 focus:ring-blue-600/20 focus:border-blue-600 disabled:bg-slate-100 disabled:text-slate-500"
            >
              {SIMULATED_PORTS.map((p) => (
                <option key={p.port} value={p.port}>
                  {p.port} — {p.friendlyName}
                  {p.isRecommended ? ' (Рекомендуемый)' : ''}
                </option>
              ))}
            </select>
          </div>

          <button
            type="button"
            disabled={connected || scanning}
            onClick={handleScanPorts}
            className="inline-flex items-center gap-2 h-10 px-4 text-sm font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 disabled:opacity-50 transition-colors whitespace-nowrap shrink-0"
          >
            <RefreshCw className={`w-4 h-4 ${scanning ? 'animate-spin' : ''}`} />
            Обновить порты
          </button>

          <button
            type="button"
            onClick={handleToggleConnect}
            className={`inline-flex items-center gap-2 h-10 px-4 text-sm font-medium rounded-lg transition-colors whitespace-nowrap shrink-0 ${
              connected
                ? 'bg-slate-900 text-white hover:bg-slate-800'
                : 'bg-blue-700 text-white hover:bg-blue-800'
            }`}
          >
            <Power className="w-4 h-4" />
            {connected ? 'Отключить порт' : 'Подключить модем'}
          </button>
        </div>

        {/* Inline notification bar when action completes */}
        {statusNotice && (
          <div className="flex items-center justify-between px-5 py-2.5 bg-blue-50 border-b border-blue-200 text-xs text-blue-900">
            <span className="flex items-center gap-2">
              <Check className="w-3.5 h-3.5 text-blue-700 shrink-0" />
              {statusNotice}
            </span>
            <button
              type="button"
              onClick={() => setStatusNotice('')}
              className="text-blue-700 hover:text-blue-900 font-medium whitespace-nowrap"
            >
              Скрыть
            </button>
          </div>
        )}

        {/* Inner Windows Navigation + Viewport */}
        <div className="grid grid-cols-1 lg:grid-cols-[210px_1fr] min-h-[540px]">
          {/* Flutter NavigationRail mirror */}
          <div className="flex lg:flex-col gap-1 p-3 bg-slate-50 border-b lg:border-b-0 lg:border-r border-slate-200 overflow-x-auto">
            {[
              { id: 'overview' as const, label: 'Обзор и сеть', icon: Signal },
              {
                id: 'sms' as const,
                label: `SMS (${smsList.length})`,
                icon: MessageSquare,
              },
              { id: 'ussd' as const, label: 'USSD-запросы', icon: Phone },
              { id: 'modes' as const, label: 'Режимы E173', icon: Settings2 },
              { id: 'terminal' as const, label: 'AT-терминал', icon: Terminal },
            ].map((item) => {
              const Icon = item.icon;
              const active = tab === item.id;
              return (
                <button
                  key={item.id}
                  type="button"
                  onClick={() => setTab(item.id)}
                  className={`flex items-center gap-2.5 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors whitespace-nowrap shrink-0 text-left ${
                    active
                      ? 'bg-blue-700 text-white'
                      : 'text-slate-700 hover:bg-slate-200/70'
                  }`}
                >
                  <Icon className="w-4 h-4 shrink-0" />
                  <span>{item.label}</span>
                </button>
              );
            })}
          </div>

          {/* Main simulated Flutter content */}
          <div className="p-6 bg-white">
            {/* TAB 1: OVERVIEW */}
            {tab === 'overview' && (
              <div className="space-y-6">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <h2 className="text-lg font-semibold text-slate-900">
                      Телеметрия Huawei E173
                    </h2>
                    <div className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-slate-500">
                      <span>Модель E173</span>
                      <span aria-hidden="true">·</span>
                      <span className="font-mono">VID_12D1 / PID_1436</span>
                      <span aria-hidden="true">·</span>
                      <span className="font-mono">Прошивка 11.126.85.00.209</span>
                    </div>
                  </div>
                  <button
                    type="button"
                    disabled={!connected}
                    onClick={() => {
                      executeAtCommand('AT+CSQ');
                      executeAtCommand('AT^SYSINFO');
                      notify('Данные сигнала и сети обновлены с модема.');
                    }}
                    className="inline-flex items-center gap-2 px-3.5 py-2 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 disabled:opacity-50 whitespace-nowrap"
                  >
                    <RefreshCw className="w-3.5 h-3.5" />
                    Опросить модем
                  </button>
                </div>

                {/* 4-column metric grid separated by hairline borders */}
                <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 border border-slate-200 rounded-lg divide-y sm:divide-y-0 sm:divide-x divide-slate-200">
                  <div className="p-4">
                    <div className="text-xs text-slate-500">Оператор и сеть</div>
                    <div className="mt-1.5 text-lg font-semibold text-slate-900">
                      {connected ? activePreset.name : 'Порт закрыт'}
                    </div>
                    <div className="mt-1 text-xs text-slate-600 font-mono">
                      {connected ? currentTech : 'Нет опроса'}
                    </div>
                  </div>

                  <div className="p-4">
                    <div className="flex items-center justify-between">
                      <span className="text-xs text-slate-500">Уровень сигнала</span>
                      <div className="flex items-end gap-0.5 h-3.5" aria-label={`Сигнал ${bars} из 5`}>
                        {[1, 2, 3, 4, 5].map((lvl) => (
                          <span
                            key={lvl}
                            style={{ height: `${lvl * 20}%` }}
                            className={`w-1 rounded-xs ${
                              connected && lvl <= bars
                                ? bars >= 3
                                  ? 'bg-emerald-600'
                                  : 'bg-amber-500'
                                : 'bg-slate-200'
                            }`}
                          />
                        ))}
                      </div>
                    </div>
                    <div className="mt-1.5 text-lg font-semibold text-slate-900 font-mono tabular-nums">
                      {connected && dbm !== null ? `${dbm} dBm` : '—'}
                    </div>
                    <div className="mt-1 text-xs text-slate-600 font-mono tabular-nums">
                      {connected ? `CSQ ${rssi}/31 · ${signalPct}%` : 'Нет сигнала'}
                    </div>
                  </div>

                  <div className="p-4">
                    <div className="text-xs text-slate-500">SIM и блокировка</div>
                    <div
                      className={`mt-1.5 text-lg font-semibold ${
                        connected ? 'text-emerald-700' : 'text-slate-400'
                      }`}
                    >
                      {connected ? 'SIM готова' : '—'}
                    </div>
                    <div className="mt-1 text-xs text-slate-600">
                      {cardUnlocked ? 'Разблокирован (все SIM)' : 'Операторский блок (NCK)'}
                    </div>
                  </div>

                  <div className="p-4">
                    <div className="text-xs text-slate-500">Идентификаторы</div>
                    <div className="mt-1.5 text-sm font-semibold text-slate-900 font-mono tabular-nums">
                      358941042187349
                    </div>
                    <div className="mt-1 text-xs text-slate-600 font-mono">
                      U2DIAG: {u2diagMode}
                    </div>
                  </div>
                </div>

                {/* Interactive signal test slider */}
                <div className="pt-2 border-t border-slate-100">
                  <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-slate-600">
                    <label htmlFor="rssi-sim" className="font-medium text-slate-700">
                      Имитация уровня RSSI (AT+CSQ) для проверки шкалы сигнала
                    </label>
                    <span className="font-mono tabular-nums">
                      CSQ {rssi} → {dbm !== null ? `${dbm} dBm` : 'Неизвестно'}
                    </span>
                  </div>
                  <input
                    id="rssi-sim"
                    type="range"
                    min={0}
                    max={31}
                    value={rssi}
                    disabled={!connected}
                    onChange={(e) => setRssi(Number(e.target.value))}
                    className="mt-2 w-full accent-blue-700 cursor-pointer disabled:opacity-40"
                  />
                </div>

                {/* RAS Dial-Up panel */}
                {config.enableRasDialer && (
                  <div className="pt-5 border-t border-slate-200 space-y-3">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div>
                        <h3 className="text-sm font-semibold text-slate-900">
                          Подключение к интернету (Windows RAS Dial-Up)
                        </h3>
                        <p className="text-xs text-slate-500">
                          Использует встроенный rasdial.exe и портативную книгу huawei_e173.pbk рядом с .exe
                        </p>
                      </div>
                      <span
                        className={`text-xs font-medium ${
                          rasConnected ? 'text-emerald-700' : 'text-slate-500'
                        }`}
                      >
                        {rasConnected
                          ? `Подключено · ${formatDuration(rasSeconds)}`
                          : 'Соединение не активно'}
                      </span>
                    </div>

                    <div className="flex flex-wrap items-center gap-3">
                      <div className="flex-1 min-w-[200px]">
                        <label htmlFor="sim-apn" className="block text-xs text-slate-500 mb-1">
                          Точка доступа APN (AT+CGDCONT)
                        </label>
                        <input
                          id="sim-apn"
                          type="text"
                          value={apn}
                          disabled={rasConnected}
                          onChange={(e) => setApn(e.target.value)}
                          className="w-full h-9 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600 disabled:bg-slate-50"
                        />
                      </div>

                      <div className="pt-5">
                        <button
                          type="button"
                          disabled={!connected}
                          onClick={handleToggleRas}
                          className={`inline-flex items-center gap-2 h-9 px-4 text-sm font-medium rounded-lg transition-colors whitespace-nowrap ${
                            rasConnected
                              ? 'bg-red-600 text-white hover:bg-red-700'
                              : 'bg-blue-700 text-white hover:bg-blue-800'
                          } disabled:opacity-40`}
                        >
                          <Wifi className="w-4 h-4" />
                          {rasConnected ? 'Разорвать интернет' : 'Подключить интернет'}
                        </button>
                      </div>
                    </div>

                    {rasConnected && (
                      <div className="flex flex-wrap items-center gap-6 pt-2 text-xs text-slate-600 font-mono tabular-nums">
                        <span className="inline-flex items-center gap-1.5">
                          <ArrowDownUp className="w-3.5 h-3.5 text-blue-700" />
                          Принято: {(rxKb / 1024).toFixed(2)} МБ
                        </span>
                        <span>Отправлено: {(txKb / 1024).toFixed(2)} МБ</span>
                        <span>Номер дозвона: {config.customDialNumber}</span>
                      </div>
                    )}
                  </div>
                )}
              </div>
            )}

            {/* TAB 2: SMS */}
            {tab === 'sms' && (
              <div className="space-y-5">
                <form onSubmit={handleSendSms} className="space-y-3 pb-5 border-b border-slate-200">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <h2 className="text-base font-semibold text-slate-900">
                      Отправка SMS (автокодирование UCS2 для кириллицы)
                    </h2>
                    <span className="text-xs text-slate-500 font-mono tabular-nums">
                      {smsText.length} / 70 симв. (1 сегмент UCS2)
                    </span>
                  </div>

                  <div className="grid grid-cols-1 md:grid-cols-[200px_1fr_auto] gap-3">
                    <input
                      type="text"
                      value={smsPhone}
                      onChange={(e) => setSmsPhone(e.target.value)}
                      placeholder="+79990001122"
                      className="h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                    />
                    <input
                      type="text"
                      value={smsText}
                      onChange={(e) => setSmsText(e.target.value)}
                      placeholder="Введите текст SMS на русском или латинице..."
                      className="h-10 px-3 text-sm border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                    />
                    <button
                      type="submit"
                      disabled={!connected || !smsText.trim()}
                      className="inline-flex items-center justify-center gap-2 h-10 px-4 text-sm font-medium bg-blue-700 text-white rounded-lg hover:bg-blue-800 disabled:opacity-40 whitespace-nowrap"
                    >
                      <Send className="w-4 h-4" />
                      Отправить
                    </button>
                  </div>

                  {smsText.trim().length > 0 && (
                    <div className="text-xs text-slate-500 font-mono break-all bg-slate-50 px-3 py-2 rounded-md border border-slate-200">
                      UCS2 HEX (AT+CMGS): {encodeUcs2Hex(smsText)}
                    </div>
                  )}
                </form>

                {/* Filter + SMS List */}
                <div className="space-y-3">
                  <div className="flex items-center justify-between gap-3">
                    <h3 className="text-sm font-semibold text-slate-900">
                      Сообщения в памяти модема / SIM
                    </h3>
                    <input
                      type="search"
                      value={smsSearch}
                      onChange={(e) => setSmsSearch(e.target.value)}
                      placeholder="Поиск по номеру или тексту..."
                      className="h-8 w-56 px-2.5 text-xs border border-slate-300 rounded-md focus:outline-none focus:border-blue-600"
                    />
                  </div>

                  {filteredSms.length === 0 ? (
                    <div className="py-10 text-center text-sm text-slate-500 border border-dashed border-slate-200 rounded-lg">
                      Сообщения не найдены. Отправьте тестовое SMS или сбросьте фильтр.
                    </div>
                  ) : (
                    <div className="divide-y divide-slate-200 border border-slate-200 rounded-lg">
                      {filteredSms.map((msg) => (
                        <div
                          key={msg.id}
                          className="flex items-start justify-between gap-4 p-3.5 hover:bg-slate-50/70 transition-colors"
                        >
                          <div className="min-w-0 space-y-1">
                            <div className="flex flex-wrap items-center gap-2 text-xs text-slate-500">
                              <span className="font-semibold text-slate-900 font-mono">
                                {msg.phone}
                              </span>
                              <span aria-hidden="true">·</span>
                              <span>
                                {msg.direction === 'in' ? 'Входящее' : 'Отправлено'}
                              </span>
                              <span aria-hidden="true">·</span>
                              <span className="font-mono tabular-nums">{msg.timestamp}</span>
                            </div>
                            <p className="text-sm text-slate-800">{msg.text}</p>
                          </div>
                          <button
                            type="button"
                            title="Удалить SMS (AT+CMGD)"
                            onClick={() => {
                              setSmsList((prev) => prev.filter((x) => x.id !== msg.id));
                              appendLog('tx', `AT+CMGD=${msg.id % 50}`);
                              appendLog('rx', 'OK');
                            }}
                            className="p-2 text-slate-400 hover:text-red-600 transition-colors shrink-0"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* TAB 3: USSD */}
            {tab === 'ussd' && (
              <div className="space-y-5">
                <div>
                  <h2 className="text-base font-semibold text-slate-900">
                    USSD-запросы (AT+CUSD с декодированием UCS2)
                  </h2>
                  <p className="mt-1 text-xs text-slate-500">
                    Быстрые кнопки автоматически синхронизируются с разделом «Конфигуратор проекта».
                  </p>
                </div>

                <div className="flex flex-wrap gap-2">
                  {config.ussdShortcuts.map((shortcut) => (
                    <button
                      key={shortcut.id}
                      type="button"
                      disabled={!connected}
                      onClick={() => handleSendUssd(shortcut.code)}
                      className="px-3.5 py-2 text-xs font-medium text-slate-700 bg-slate-50 border border-slate-200 rounded-lg hover:bg-slate-100 disabled:opacity-40 transition-colors whitespace-nowrap"
                    >
                      {shortcut.label}{' '}
                      <span className="font-mono text-slate-500 ml-1">{shortcut.code}</span>
                    </button>
                  ))}
                </div>

                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    handleSendUssd(ussdInput);
                  }}
                  className="flex flex-wrap items-center gap-3"
                >
                  <input
                    type="text"
                    value={ussdInput}
                    onChange={(e) => setUssdInput(e.target.value)}
                    placeholder="*100#"
                    className="h-10 w-56 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                  />
                  <button
                    type="submit"
                    disabled={!connected || !ussdInput.trim()}
                    className="h-10 px-4 text-sm font-medium bg-blue-700 text-white rounded-lg hover:bg-blue-800 disabled:opacity-40 whitespace-nowrap"
                  >
                    Отправить запрос
                  </button>
                </form>

                {ussdResult && (
                  <div className="p-4 bg-slate-50 border border-slate-200 rounded-lg space-y-2.5">
                    <div className="flex items-center justify-between text-xs text-slate-500">
                      <span>
                        Запрос <strong className="font-mono text-slate-800">{ussdResult.code}</strong>
                      </span>
                      <span className="font-mono tabular-nums">{ussdResult.time}</span>
                    </div>
                    <p className="text-sm text-slate-900 font-medium leading-relaxed">
                      {ussdResult.decoded}
                    </p>
                    <div className="pt-2 border-t border-slate-200 text-xs font-mono text-slate-500 break-all">
                      Сырой ответ UCS2: {ussdResult.rawHex.slice(0, 96)}
                      {ussdResult.rawHex.length > 96 ? '...' : ''}
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* TAB 4: E173 MODES */}
            {tab === 'modes' && (
              <div className="space-y-6">
                {/* Network preference */}
                <div className="space-y-3">
                  <div className="flex items-center gap-2">
                    <Antenna className="w-4 h-4 text-blue-700" />
                    <h2 className="text-base font-semibold text-slate-900">
                      Диапазон сотовой сети (AT^SYSCFG)
                    </h2>
                  </div>
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
                    {SYSCFG_MODES.map((m) => {
                      const active = networkMode === m.value;
                      return (
                        <button
                          key={m.value}
                          type="button"
                          disabled={!connected}
                          onClick={() => handleApplySyscfg(m.value, m.code)}
                          className={`p-3.5 text-left border rounded-lg transition-colors disabled:opacity-40 ${
                            active
                              ? 'border-blue-700 bg-blue-50/60'
                              : 'border-slate-200 hover:bg-slate-50'
                          }`}
                        >
                          <div className="flex items-center justify-between gap-2">
                            <span className="text-sm font-semibold text-slate-900">
                              {m.label}
                            </span>
                            <span className="text-xs text-slate-500">{m.tech}</span>
                          </div>
                          <div className="mt-1 text-xs font-mono text-slate-500">
                            {m.code}
                          </div>
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* U2DIAG Mode Switcher */}
                {config.enableU2DiagTools && (
                  <div className="pt-5 border-t border-slate-200 space-y-3">
                    <h3 className="text-base font-semibold text-slate-900">
                      Композитный USB-режим Huawei E173 (AT^U2DIAG)
                    </h3>
                    <div className="divide-y divide-slate-200 border border-slate-200 rounded-lg">
                      {U2DIAG_MODES.map((m) => {
                        const active = u2diagMode === m.value;
                        return (
                          <div
                            key={m.value}
                            className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-3.5"
                          >
                            <div className="space-y-0.5">
                              <div className="flex items-center gap-2">
                                <span className="text-sm font-semibold text-slate-900">
                                  {m.title}
                                </span>
                                <span className="text-xs font-mono text-slate-500">
                                  {m.code}
                                </span>
                              </div>
                              <p className="text-xs text-slate-600">{m.summary}</p>
                            </div>
                            <button
                              type="button"
                              disabled={!connected || active}
                              onClick={() => executeAtCommand(m.code)}
                              className={`px-3.5 py-2 text-xs font-medium rounded-lg whitespace-nowrap shrink-0 ${
                                active
                                  ? 'bg-slate-100 text-slate-500'
                                  : 'bg-white border border-slate-300 text-slate-800 hover:bg-slate-50'
                              }`}
                            >
                              {active ? 'Активен' : 'Применить'}
                            </button>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}

                {/* NCK unlock & Reboot */}
                <div className="pt-5 border-t border-slate-200 flex flex-wrap items-end justify-between gap-4">
                  <div className="flex flex-wrap items-end gap-2.5">
                    <div>
                      <label htmlFor="nck-code" className="block text-xs text-slate-600 mb-1">
                        Разблокировка оператора (AT^CARDLOCK)
                      </label>
                      <input
                        id="nck-code"
                        type="text"
                        maxLength={8}
                        value={nckInput}
                        onChange={(e) => setNckInput(e.target.value.replace(/\D/g, ''))}
                        placeholder="8-значный NCK код"
                        className="h-9 w-48 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                      />
                    </div>
                    <button
                      type="button"
                      disabled={!connected || nckInput.length < 8}
                      onClick={() => {
                        executeAtCommand(`AT^CARDLOCK="${nckInput}"`);
                        setCardUnlocked(true);
                        setNckInput('');
                        notify('NCK-код принят. Модем разблокирован для всех операторов.');
                      }}
                      className="h-9 px-3.5 text-xs font-medium bg-slate-900 text-white rounded-lg hover:bg-slate-800 disabled:opacity-40 whitespace-nowrap"
                    >
                      Ввести NCK
                    </button>
                  </div>

                  <button
                    type="button"
                    disabled={!connected}
                    onClick={() => executeAtCommand('AT+CFUN=1,1')}
                    className="h-9 px-3.5 text-xs font-medium text-red-700 bg-white border border-red-200 rounded-lg hover:bg-red-50 disabled:opacity-40 whitespace-nowrap"
                  >
                    Перезагрузить модем (AT+CFUN=1,1)
                  </button>
                </div>
              </div>
            )}

            {/* TAB 5: AT TERMINAL */}
            {tab === 'terminal' && (
              <div className="space-y-4">
                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    executeAtCommand(atInput);
                  }}
                  className="flex flex-wrap items-center gap-2.5"
                >
                  <input
                    type="text"
                    value={atInput}
                    onChange={(e) => setAtInput(e.target.value)}
                    placeholder="Введите AT-команду (например ATI, AT+CSQ, AT^U2DIAG?)"
                    className="flex-1 min-w-[220px] h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                  />
                  <button
                    type="submit"
                    disabled={!connected}
                    className="h-10 px-4 text-sm font-medium bg-blue-700 text-white rounded-lg hover:bg-blue-800 disabled:opacity-40 whitespace-nowrap"
                  >
                    Выполнить
                  </button>
                  <button
                    type="button"
                    onClick={() => setAtLogs([])}
                    className="h-10 px-3.5 text-sm font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
                  >
                    Очистить
                  </button>
                </form>

                {/* Quick commands */}
                <div className="flex flex-wrap gap-1.5">
                  {AT_QUICK_COMMANDS.map((q) => (
                    <button
                      key={q.cmd}
                      type="button"
                      disabled={!connected}
                      title={q.desc}
                      onClick={() => {
                        setAtInput(q.cmd);
                        executeAtCommand(q.cmd);
                      }}
                      className="px-2.5 py-1.5 text-xs font-mono text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-md disabled:opacity-40 transition-colors whitespace-nowrap"
                    >
                      {q.cmd}
                    </button>
                  ))}
                </div>

                {/* Console output */}
                <div className="h-80 overflow-y-auto bg-slate-950 text-slate-100 rounded-lg p-4 font-mono text-xs space-y-1.5">
                  {atLogs.length === 0 ? (
                    <div className="text-slate-500">
                      Журнал пуст. Отправьте любую AT-команду для проверки ответа Huawei E173.
                    </div>
                  ) : (
                    atLogs.map((entry) => (
                      <div key={entry.id} className="flex items-start gap-3 leading-relaxed">
                        <span className="text-slate-500 shrink-0 tabular-nums">
                          {entry.time}
                        </span>
                        <span
                          className={`w-9 shrink-0 font-semibold ${
                            entry.direction === 'tx'
                              ? 'text-blue-400'
                              : entry.direction === 'rx'
                              ? 'text-emerald-400'
                              : 'text-amber-400'
                          }`}
                        >
                          {entry.direction.toUpperCase()}
                        </span>
                        <span className="break-all text-slate-200">{entry.text}</span>
                      </div>
                    ))
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
