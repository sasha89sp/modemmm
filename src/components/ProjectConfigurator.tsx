import React, { useState } from 'react';
import { Plus, RotateCcw, Trash2 } from 'lucide-react';
import { DEFAULT_PROJECT_CONFIG, OPERATOR_PRESETS } from '../data/presets';
import { ProjectConfig } from '../types/project';

interface ProjectConfiguratorProps {
  config: ProjectConfig;
  onChange: (next: ProjectConfig) => void;
}

export const ProjectConfigurator: React.FC<ProjectConfiguratorProps> = ({
  config,
  onChange,
}) => {
  const [newUssdLabel, setNewUssdLabel] = useState('');
  const [newUssdCode, setNewUssdCode] = useState('');

  const update = <K extends keyof ProjectConfig>(
    key: K,
    value: ProjectConfig[K]
  ) => {
    onChange({ ...config, [key]: value });
  };

  const handleAddUssd = (e: React.FormEvent) => {
    e.preventDefault();
    const label = newUssdLabel.trim();
    const code = newUssdCode.trim();
    if (!label || !code) return;
    update('ussdShortcuts', [
      ...config.ussdShortcuts,
      { id: `u-${Date.now()}`, label, code },
    ]);
    setNewUssdLabel('');
    setNewUssdCode('');
  };

  const handleRemoveUssd = (id: string) => {
    update(
      'ussdShortcuts',
      config.ussdShortcuts.filter((item) => item.id !== id)
    );
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-slate-900">
            Конфигуратор Flutter-сборки
          </h1>
          <p className="mt-1 text-sm text-slate-600 max-w-2xl">
            Все изменения мгновенно обновляют исходный код Dart, pubspec.yaml и сценарий GitHub Actions перед выгрузкой ZIP-архива.
          </p>
        </div>

        <button
          type="button"
          onClick={() => onChange(DEFAULT_PROJECT_CONFIG)}
          className="inline-flex items-center gap-2 px-3.5 py-2 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
        >
          <RotateCcw className="w-3.5 h-3.5" />
          Сбросить по умолчанию
        </button>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* General & Serial Parameters */}
        <section className="bg-white border border-slate-200 rounded-xl p-6 space-y-5">
          <h2 className="text-base font-semibold text-slate-900">
            Основные параметры приложения
          </h2>

          <div className="space-y-4">
            <div>
              <label
                htmlFor="cfg-title"
                className="block text-xs font-medium text-slate-700 mb-1.5"
              >
                Заголовок окна Windows
              </label>
              <input
                id="cfg-title"
                type="text"
                value={config.appTitle}
                onChange={(e) => update('appTitle', e.target.value)}
                className="w-full h-10 px-3 text-sm border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
              />
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label
                  htmlFor="cfg-pkg"
                  className="block text-xs font-medium text-slate-700 mb-1.5"
                >
                  Имя пакета и .exe файла (латиница)
                </label>
                <input
                  id="cfg-pkg"
                  type="text"
                  value={config.packageName}
                  onChange={(e) =>
                    update(
                      'packageName',
                      e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_')
                    )
                  }
                  className="w-full h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                />
              </div>

              <div>
                <label
                  htmlFor="cfg-ver"
                  className="block text-xs font-medium text-slate-700 mb-1.5"
                >
                  Версия в pubspec.yaml
                </label>
                <input
                  id="cfg-ver"
                  type="text"
                  value={config.version}
                  onChange={(e) => update('version', e.target.value)}
                  className="w-full h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                />
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label
                  htmlFor="cfg-baud"
                  className="block text-xs font-medium text-slate-700 mb-1.5"
                >
                  Скорость COM-порта (Baud Rate)
                </label>
                <select
                  id="cfg-baud"
                  value={config.defaultBaudRate}
                  onChange={(e) =>
                    update('defaultBaudRate', Number(e.target.value))
                  }
                  className="w-full h-10 px-3 text-sm font-mono bg-white border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                >
                  <option value={115200}>115200 (Рекомендуется для E173)</option>
                  <option value={57600}>57600</option>
                  <option value={38400}>38400</option>
                  <option value={9600}>9600</option>
                </select>
              </div>

              <div>
                <label
                  htmlFor="cfg-op"
                  className="block text-xs font-medium text-slate-700 mb-1.5"
                >
                  Оператор / профиль APN по умолчанию
                </label>
                <select
                  id="cfg-op"
                  value={config.defaultOperatorId}
                  onChange={(e) => update('defaultOperatorId', e.target.value)}
                  className="w-full h-10 px-3 text-sm bg-white border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                >
                  {OPERATOR_PRESETS.map((op) => (
                    <option key={op.id} value={op.id}>
                      {op.name} ({op.apn})
                    </option>
                  ))}
                </select>
              </div>
            </div>

            {config.defaultOperatorId === 'custom' && (
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <label
                    htmlFor="cfg-custom-apn"
                    className="block text-xs font-medium text-slate-700 mb-1.5"
                  >
                    Свой APN
                  </label>
                  <input
                    id="cfg-custom-apn"
                    type="text"
                    value={config.customApn}
                    onChange={(e) => update('customApn', e.target.value)}
                    className="w-full h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                  />
                </div>
                <div>
                  <label
                    htmlFor="cfg-dial"
                    className="block text-xs font-medium text-slate-700 mb-1.5"
                  >
                    Номер дозвона RAS
                  </label>
                  <input
                    id="cfg-dial"
                    type="text"
                    value={config.customDialNumber}
                    onChange={(e) => update('customDialNumber', e.target.value)}
                    className="w-full h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                  />
                </div>
              </div>
            )}
          </div>
        </section>

        {/* Modules & GitHub Actions options */}
        <section className="bg-white border border-slate-200 rounded-xl p-6 space-y-5">
          <h2 className="text-base font-semibold text-slate-900">
            Модули портативности и GitHub Actions
          </h2>

          <div className="divide-y divide-slate-200">
            {[
              {
                key: 'portableConfigNextToExe' as const,
                title: 'Хранить config.json рядом с .exe',
                desc: 'Полностью портативный режим без записи в AppData и реестр Windows.',
              },
              {
                key: 'autoConnectPort' as const,
                title: 'Автоподключение к порту при запуске',
                desc: 'Сразу открывает последний сохранённый или найденный Huawei PC UI порт.',
              },
              {
                key: 'enableRasDialer' as const,
                title: 'Встроенный менеджер интернета (Windows RAS)',
                desc: 'Подключает 3G-интернет через rasdial.exe с локальной книгой huawei_e173.pbk.',
              },
              {
                key: 'enableU2DiagTools' as const,
                title: 'Инструменты AT^U2DIAG (CD-ROM / MicroSD)',
                desc: 'Кнопки перевода E173 в режим «Только модем» (0), MicroSD (256) или заводской (255).',
              },
              {
                key: 'githubReleaseOnTag' as const,
                title: 'Автопубликация GitHub Release по тегу v*',
                desc: 'При git push origin v1.0.0 прикрепляет готовый ZIP к разделу Releases.',
              },
              {
                key: 'githubIncludeSfxBatch' as const,
                title: 'Добавить Start_Portable.bat в архив',
                desc: 'Удобный батник запуска с фиксацией рабочей директории для USB-флешек.',
              },
            ].map((item) => (
              <label
                key={item.key}
                className="flex items-start justify-between gap-4 py-3 first:pt-0 last:pb-0 cursor-pointer"
              >
                <div>
                  <div className="text-sm font-medium text-slate-900">
                    {item.title}
                  </div>
                  <div className="text-xs text-slate-500 mt-0.5">{item.desc}</div>
                </div>
                <input
                  type="checkbox"
                  checked={config[item.key]}
                  onChange={(e) => update(item.key, e.target.checked)}
                  className="mt-1 h-4 w-4 rounded border-slate-300 accent-blue-700 shrink-0"
                />
              </label>
            ))}
          </div>
        </section>
      </div>

      {/* USSD shortcuts editor */}
      <section className="bg-white border border-slate-200 rounded-xl p-6 space-y-4">
        <div>
          <h2 className="text-base font-semibold text-slate-900">
            Быстрые USSD-кнопки в скомпилированной программе
          </h2>
          <p className="text-xs text-slate-500 mt-0.5">
            Зашиваются в PortableConfig.defaultShortcuts и сразу доступны на вкладке USSD.
          </p>
        </div>

        <form onSubmit={handleAddUssd} className="flex flex-wrap items-center gap-3">
          <input
            type="text"
            value={newUssdLabel}
            onChange={(e) => setNewUssdLabel(e.target.value)}
            placeholder="Название (например, Остаток минут)"
            className="h-10 flex-1 min-w-[200px] px-3 text-sm border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
          />
          <input
            type="text"
            value={newUssdCode}
            onChange={(e) => setNewUssdCode(e.target.value)}
            placeholder="Код (*100*1#)"
            className="h-10 w-44 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
          />
          <button
            type="submit"
            disabled={!newUssdLabel.trim() || !newUssdCode.trim()}
            className="inline-flex items-center gap-2 h-10 px-4 text-sm font-medium bg-slate-900 text-white rounded-lg hover:bg-slate-800 disabled:opacity-40 whitespace-nowrap"
          >
            <Plus className="w-4 h-4" />
            Добавить
          </button>
        </form>

        <div className="divide-y divide-slate-200 border border-slate-200 rounded-lg">
          {config.ussdShortcuts.map((item) => (
            <div
              key={item.id}
              className="flex items-center justify-between gap-4 px-4 py-2.5 text-sm"
            >
              <div className="flex items-center gap-3 min-w-0">
                <span className="font-medium text-slate-900 truncate">
                  {item.label}
                </span>
                <span className="text-slate-300" aria-hidden="true">
                  ·
                </span>
                <span className="font-mono text-xs text-slate-600">
                  {item.code}
                </span>
              </div>
              <button
                type="button"
                onClick={() => handleRemoveUssd(item.id)}
                className="p-1.5 text-slate-400 hover:text-red-600 transition-colors"
                aria-label={`Удалить ${item.label}`}
              >
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
};
