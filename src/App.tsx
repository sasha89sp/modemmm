import { useMemo, useState } from 'react';
import {
  Check,
  Code2,
  Download,
  GitBranch,
  Monitor,
  SlidersHorizontal,
} from 'lucide-react';
import { CodeExplorer } from './components/CodeExplorer';
import { GitHubGuide } from './components/GitHubGuide';
import { ModemSimulator } from './components/ModemSimulator';
import { ProjectConfigurator } from './components/ProjectConfigurator';
import { DEFAULT_PROJECT_CONFIG } from './data/presets';
import { generateFlutterProject } from './generators/flutterProjectGenerator';
import { ProjectConfig } from './types/project';
import { downloadProjectZip } from './utils/downloadZip';

type WorkspaceSection = 'simulator' | 'config' | 'code' | 'github';

const NAV_ITEMS: {
  id: WorkspaceSection;
  label: string;
  breadcrumb: string;
  icon: typeof Monitor;
}[] = [
  {
    id: 'simulator',
    label: 'Макет программы',
    breadcrumb: 'Интерактивный макет E173',
    icon: Monitor,
  },
  {
    id: 'config',
    label: 'Конфигуратор',
    breadcrumb: 'Конфигуратор Flutter-сборки',
    icon: SlidersHorizontal,
  },
  {
    id: 'code',
    label: 'Исходный код',
    breadcrumb: 'Исходный код и GitHub Actions',
    icon: Code2,
  },
  {
    id: 'github',
    label: 'Загрузка на GitHub',
    breadcrumb: 'Прямая загрузка и сборка на GitHub',
    icon: GitBranch,
  },
];

export default function App() {
  const [section, setSection] = useState<WorkspaceSection>('github');
  const [config, setConfig] = useState<ProjectConfig>(DEFAULT_PROJECT_CONFIG);
  const [downloading, setDownloading] = useState(false);
  const [downloadedRecently, setDownloadedRecently] = useState(false);

  const generatedFiles = useMemo(
    () => generateFlutterProject(config),
    [config]
  );

  const activeNav =
    NAV_ITEMS.find((item) => item.id === section) || NAV_ITEMS[0];

  const handleDownloadZip = async () => {
    if (downloading) return;
    setDownloading(true);
    try {
      await downloadProjectZip(generatedFiles, config.packageName);
      setDownloadedRecently(true);
      window.setTimeout(() => setDownloadedRecently(false), 2600);
    } finally {
      setDownloading(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 text-slate-900 flex flex-col lg:flex-row">
      {/* Desktop Sidebar (248px) */}
      <aside className="hidden lg:flex lg:flex-col lg:w-[248px] lg:shrink-0 bg-white border-r border-slate-200">
        <div className="h-16 flex items-center px-6 border-b border-slate-200">
          <span className="text-base font-bold tracking-tight text-slate-900 whitespace-nowrap">
            Huawei E173 Builder
          </span>
        </div>

        <nav className="flex-1 p-3 space-y-1" aria-label="Разделы рабочей области">
          {NAV_ITEMS.map((item) => {
            const Icon = item.icon;
            const active = section === item.id;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => setSection(item.id)}
                className={`w-full flex items-center gap-3 px-3.5 py-2.5 rounded-lg text-sm font-medium transition-colors whitespace-nowrap text-left ${
                  active
                    ? 'bg-slate-900 text-white'
                    : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900'
                }`}
              >
                <Icon className="w-4 h-4 shrink-0" />
                <span>{item.label}</span>
              </button>
            );
          })}
        </nav>

        <div className="p-5 border-t border-slate-200 space-y-2 text-xs text-slate-500">
          <div className="font-medium text-slate-800">Целевая сборка</div>
          <div>Flutter 3.24+ · Windows x64</div>
          <div className="font-mono text-slate-600">
            {generatedFiles.length} файлов · Win32 FFI
          </div>
        </div>
      </aside>

      {/* Main Content Area */}
      <div className="flex-1 flex flex-col min-w-0">
        {/* Top Bar Contract: Breadcrumb on left, 1 primary CTA on right */}
        <header className="sticky top-0 z-20 h-16 bg-white border-b border-slate-200 px-4 sm:px-6 lg:px-8 flex items-center justify-between gap-6">
          <div className="flex items-center gap-2 text-sm min-w-0">
            <span className="font-semibold text-slate-900 whitespace-nowrap lg:hidden">
              Huawei E173 Builder
            </span>
            <span className="hidden lg:inline text-slate-500 whitespace-nowrap">
              Huawei E173 Builder
            </span>
            <span className="text-slate-300" aria-hidden="true">
              /
            </span>
            <span className="font-medium text-slate-900 truncate">
              {activeNav.breadcrumb}
            </span>
          </div>

          <button
            type="button"
            disabled={downloading}
            onClick={handleDownloadZip}
            className="inline-flex items-center gap-2 h-10 px-4 text-sm font-medium text-white bg-blue-700 hover:bg-blue-800 disabled:opacity-60 rounded-lg transition-colors whitespace-nowrap shrink-0"
          >
            {downloadedRecently ? (
              <>
                <Check className="w-4 h-4" />
                Архив скачан
              </>
            ) : (
              <>
                <Download className="w-4 h-4" />
                {downloading ? 'Упаковка ZIP...' : 'Скачать ZIP для GitHub'}
              </>
            )}
          </button>
        </header>

        {/* Mobile navigation strip */}
        <nav
          className="lg:hidden flex items-center gap-1 px-4 py-2 bg-white border-b border-slate-200 overflow-x-auto"
          aria-label="Мобильная навигация"
        >
          {NAV_ITEMS.map((item) => {
            const active = section === item.id;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => setSection(item.id)}
                className={`px-3 py-2 text-xs font-medium rounded-lg transition-colors whitespace-nowrap shrink-0 ${
                  active
                    ? 'bg-slate-900 text-white'
                    : 'text-slate-600 hover:bg-slate-100'
                }`}
              >
                {item.label}
              </button>
            );
          })}
        </nav>

        {/* Active Viewport */}
        <main className="flex-1 w-full max-w-[1200px] mx-auto px-4 sm:px-6 lg:px-8 py-8">
          {section === 'simulator' && <ModemSimulator config={config} />}
          {section === 'config' && (
            <ProjectConfigurator config={config} onChange={setConfig} />
          )}
          {section === 'code' && <CodeExplorer files={generatedFiles} />}
          {section === 'github' && (
            <GitHubGuide
              config={config}
              files={generatedFiles}
              onDownloadZip={handleDownloadZip}
            />
          )}
        </main>
      </div>
    </div>
  );
}
