import React, { useCallback, useEffect, useState } from 'react';
import {
  Check,
  Copy,
  Download,
  ExternalLink,
  GitBranch,
  LogOut,
  RefreshCw,
  UploadCloud,
} from 'lucide-react';
import { GeneratedFile, ProjectConfig } from '../types/project';

interface GitHubUser {
  login: string;
  name: string | null;
  avatar_url: string;
  html_url: string;
}

interface PublishResult {
  repoUrl: string;
  actionsUrl: string;
  commitSha: string;
  defaultBranch: string;
  filesCount: number;
}

interface GitHubGuideProps {
  config: ProjectConfig;
  files: GeneratedFile[];
  onDownloadZip: () => void;
}

export const GitHubGuide: React.FC<GitHubGuideProps> = ({
  config,
  files,
  onDownloadZip,
}) => {
  const [copiedId, setCopiedId] = useState<string | null>(null);

  // Server OAuth status & session (kept strictly in React memory)
  const [statusLoading, setStatusLoading] = useState<boolean>(true);
  const [oauthConfigured, setOauthConfigured] = useState<boolean>(false);
  const [callbackUrl, setCallbackUrl] = useState<string>(
    `${window.location.origin}/auth/callback`
  );
  const [sessionToken, setSessionToken] = useState<string | null>(null);
  const [user, setUser] = useState<GitHubUser | null>(null);

  // Direct publish form state
  const [repoName, setRepoName] = useState<string>(config.packageName);
  const [isPrivate, setIsPrivate] = useState<boolean>(false);
  const [overwriteExisting, setOverwriteExisting] = useState<boolean>(false);
  const [connecting, setConnecting] = useState<boolean>(false);
  const [publishing, setPublishing] = useState<boolean>(false);
  const [errorMessage, setErrorMessage] = useState<string>('');
  const [publishResult, setPublishResult] = useState<PublishResult | null>(null);

  useEffect(() => {
    setRepoName(config.packageName);
  }, [config.packageName]);

  const fetchStatus = useCallback(async (tokenOverride?: string | null) => {
    setStatusLoading(true);
    try {
      const activeToken =
        tokenOverride !== undefined ? tokenOverride : sessionToken;
      const headers: Record<string, string> = {};
      if (activeToken) {
        headers.Authorization = `Bearer ${activeToken}`;
      }
      const res = await fetch('/api/github/status', { headers });
      if (res.ok) {
        const data = (await res.json()) as {
          configured: boolean;
          callbackUrl: string;
          authenticated: boolean;
          user: GitHubUser | null;
        };
        setOauthConfigured(data.configured);
        if (data.callbackUrl) setCallbackUrl(data.callbackUrl);
        if (data.authenticated && data.user) {
          setUser(data.user);
        } else {
          setUser(null);
        }
      }
    } catch {
      setErrorMessage('Не удалось связаться с локальным сервером приложения.');
    } finally {
      setStatusLoading(false);
    }
  }, [sessionToken]);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  // Listen for OAuth popup postMessage completion
  useEffect(() => {
    const handleMessage = (event: MessageEvent) => {
      const origin = event.origin || '';
      if (!origin.endsWith('.run.app') && !origin.includes('localhost')) {
        return;
      }
      const data = event.data as
        | {
            type?: string;
            sessionToken?: string;
            user?: GitHubUser;
            error?: string;
          }
        | undefined;

      if (data?.type === 'GITHUB_OAUTH_SUCCESS' && data.sessionToken) {
        setSessionToken(data.sessionToken);
        setUser(data.user || null);
        setConnecting(false);
        setErrorMessage('');
      } else if (data?.type === 'GITHUB_OAUTH_ERROR') {
        setConnecting(false);
        setErrorMessage(
          data.error || 'Не удалось завершить авторизацию через GitHub.'
        );
      }
    };
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, []);

  const handleConnectGitHub = async () => {
    setErrorMessage('');
    setConnecting(true);
    try {
      const res = await fetch('/api/github/auth-url');
      const data = (await res.json()) as { url?: string; error?: string };
      if (!res.ok || !data.url) {
        setConnecting(false);
        setErrorMessage(
          data.error || 'OAuth-приложение GitHub не настроено на сервере.'
        );
        return;
      }

      const popup = window.open(
        data.url,
        'github_oauth_popup',
        'width=620,height=720'
      );
      if (!popup) {
        setConnecting(false);
        setErrorMessage(
          'Браузер заблокировал всплывающее окно авторизации GitHub. Разрешите всплывающие окна для этого сайта и нажмите ещё раз.'
        );
      }
    } catch {
      setConnecting(false);
      setErrorMessage('Ошибка запроса URL авторизации GitHub.');
    }
  };

  const handleDisconnect = async () => {
    if (sessionToken) {
      try {
        await fetch('/api/github/disconnect', {
          method: 'POST',
          headers: { Authorization: `Bearer ${sessionToken}` },
        });
      } catch {
        // ignore network error on logout
      }
    }
    setSessionToken(null);
    setUser(null);
    setPublishResult(null);
  };

  const handlePublish = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!sessionToken) return;
    setErrorMessage('');
    setPublishResult(null);
    setPublishing(true);

    try {
      const res = await fetch('/api/github/publish', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${sessionToken}`,
        },
        body: JSON.stringify({
          repoName: repoName.trim(),
          description: `${config.appTitle} — portable Flutter Windows app for Huawei E173`,
          isPrivate,
          overwriteExisting,
          files: files.map((f) => ({ path: f.path, content: f.content })),
        }),
      });

      const data = (await res.json()) as Partial<PublishResult> & {
        error?: string;
      };
      if (!res.ok) {
        setErrorMessage(data.error || 'Не удалось опубликовать репозиторий.');
        return;
      }

      if (data.repoUrl && data.actionsUrl && data.commitSha) {
        setPublishResult({
          repoUrl: data.repoUrl,
          actionsUrl: data.actionsUrl,
          commitSha: data.commitSha,
          defaultBranch: data.defaultBranch || 'main',
          filesCount: data.filesCount || files.length,
        });
      }
    } catch {
      setErrorMessage('Сетевая ошибка при отправке файлов на GitHub.');
    } finally {
      setPublishing(false);
    }
  };

  const copyText = async (id: string, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(id);
      window.setTimeout(() => setCopiedId(null), 1800);
    } catch {
      // ignore
    }
  };

  const gitInitSnippet = `git init
git add .
git commit -m "Initial portable Flutter Windows app for Huawei E173"
git branch -M main
git remote add origin https://github.com/<ВАШ_ЛОГИН>/${config.packageName}.git
git push -u origin main`;

  const gitTagSnippet = `git tag v1.0.0
git push origin v1.0.0`;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-slate-900">
            Прямая загрузка и сборка на GitHub
          </h1>
          <p className="mt-1 text-sm text-slate-600 max-w-2xl">
            Опубликуйте сгенерированный Flutter-проект в свой GitHub-аккаунт в один клик — GitHub Actions автоматически скомпилирует портативный Windows x64 архив.
          </p>
        </div>

        <button
          type="button"
          onClick={onDownloadZip}
          className="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
        >
          <Download className="w-4 h-4" />
          Скачать ZIP локально
        </button>
      </div>

      {/* Direct GitHub OAuth Publisher */}
      <section className="bg-white border border-slate-200 rounded-xl p-6 space-y-5">
        <div className="flex flex-wrap items-center justify-between gap-3 pb-4 border-b border-slate-200">
          <div>
            <h2 className="text-base font-semibold text-slate-900">
              Загрузить напрямую в GitHub через OAuth
            </h2>
            <p className="text-xs text-slate-500 mt-0.5">
              Создаёт репозиторий и загружает все {files.length} файлов (включая workflow сборки Windows) одним коммитом.
            </p>
          </div>

          {user ? (
            <div className="flex items-center gap-3">
              <div className="text-right">
                <div className="text-xs font-semibold text-slate-900">
                  @{user.login}
                </div>
                <div className="text-xs text-emerald-700">GitHub подключён</div>
              </div>
              <button
                type="button"
                onClick={handleDisconnect}
                className="inline-flex items-center gap-1.5 h-9 px-3 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
              >
                <LogOut className="w-3.5 h-3.5" />
                Выйти
              </button>
            </div>
          ) : (
            <button
              type="button"
              onClick={() => fetchStatus()}
              disabled={statusLoading}
              className="inline-flex items-center gap-1.5 h-9 px-3 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 disabled:opacity-50 whitespace-nowrap"
            >
              <RefreshCw
                className={`w-3.5 h-3.5 ${statusLoading ? 'animate-spin' : ''}`}
              />
              Проверить статус
            </button>
          )}
        </div>

        {errorMessage && (
          <div className="p-3.5 bg-red-50 border border-red-200 rounded-lg text-xs text-red-800">
            {errorMessage}
          </div>
        )}

        {statusLoading ? (
          <div className="space-y-3 py-2">
            <div className="h-4 w-64 bg-slate-100 rounded animate-pulse" />
            <div className="h-10 w-full bg-slate-100 rounded-lg animate-pulse" />
          </div>
        ) : !oauthConfigured ? (
          <div className="space-y-4">
            <div className="text-sm text-slate-700 leading-relaxed">
              Чтобы кнопка прямой выгрузки заработала, подключите ваше GitHub OAuth-приложение в панели секретов AI Studio (достаточно сделать один раз):
            </div>

            <ol className="space-y-3 text-xs text-slate-600 list-decimal list-inside">
              <li>
                Откройте{' '}
                <a
                  href="https://github.com/settings/developers"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-blue-700 font-medium underline hover:text-blue-900"
                >
                  github.com/settings/developers
                </a>{' '}
                → <strong>OAuth Apps</strong> → <strong>New OAuth App</strong>.
              </li>
              <li>
                Укажите в поле <strong>Authorization callback URL</strong> этот адрес:
                <div className="mt-2 flex items-center gap-2">
                  <code className="flex-1 px-3 py-2 bg-slate-950 text-slate-100 rounded-lg font-mono text-xs overflow-x-auto">
                    {callbackUrl}
                  </code>
                  <button
                    type="button"
                    onClick={() => copyText('cb-url', callbackUrl)}
                    className="inline-flex items-center gap-1.5 h-9 px-3 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap shrink-0"
                  >
                    {copiedId === 'cb-url' ? (
                      <>
                        <Check className="w-3.5 h-3.5 text-emerald-600" />
                        Скопировано
                      </>
                    ) : (
                      <>
                        <Copy className="w-3.5 h-3.5" />
                        Копировать
                      </>
                    )}
                  </button>
                </div>
              </li>
              <li>
                Добавьте полученные <strong>Client ID</strong> и{' '}
                <strong>Client Secret</strong> в панель <strong>Settings → Secrets</strong> как переменные{' '}
                <code className="font-mono text-slate-800 bg-slate-100 px-1.5 py-0.5 rounded">
                  GITHUB_CLIENT_ID
                </code>{' '}
                и{' '}
                <code className="font-mono text-slate-800 bg-slate-100 px-1.5 py-0.5 rounded">
                  GITHUB_CLIENT_SECRET
                </code>
                , затем нажмите «Проверить статус».
              </li>
            </ol>
          </div>
        ) : !user ? (
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 py-1">
            <div className="text-sm text-slate-600">
              GitHub OAuth готов. Авторизуйтесь через официальное окно GitHub (запрашиваются права <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">repo</code> и <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">workflow</code> для запуска сборки Actions).
            </div>
            <button
              type="button"
              disabled={connecting}
              onClick={handleConnectGitHub}
              className="inline-flex items-center justify-center gap-2 h-10 px-5 text-sm font-medium bg-slate-900 text-white rounded-lg hover:bg-slate-800 disabled:opacity-50 whitespace-nowrap shrink-0"
            >
              <GitBranch className="w-4 h-4" />
              {connecting ? 'Ожидание входа...' : 'Войти через GitHub'}
            </button>
          </div>
        ) : (
          <form onSubmit={handlePublish} className="space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-[1fr_200px] gap-4">
              <div>
                <label
                  htmlFor="gh-repo-name"
                  className="block text-xs font-medium text-slate-700 mb-1.5"
                >
                  Имя нового репозитория ({user.login}/...)
                </label>
                <input
                  id="gh-repo-name"
                  type="text"
                  required
                  value={repoName}
                  onChange={(e) =>
                    setRepoName(e.target.value.replace(/[^a-zA-Z0-9._-]/g, '-'))
                  }
                  className="w-full h-10 px-3 text-sm font-mono border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                />
              </div>

              <div>
                <label
                  htmlFor="gh-visibility"
                  className="block text-xs font-medium text-slate-700 mb-1.5"
                >
                  Видимость репозитория
                </label>
                <select
                  id="gh-visibility"
                  value={isPrivate ? 'private' : 'public'}
                  onChange={(e) => setIsPrivate(e.target.value === 'private')}
                  className="w-full h-10 px-3 text-sm bg-white border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
                >
                  <option value="public">Публичный (Public)</option>
                  <option value="private">Приватный (Private)</option>
                </select>
              </div>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-4 pt-1">
              <label className="inline-flex items-center gap-2 text-xs text-slate-600 cursor-pointer">
                <input
                  type="checkbox"
                  checked={overwriteExisting}
                  onChange={(e) => setOverwriteExisting(e.target.checked)}
                  className="h-4 w-4 rounded border-slate-300 accent-blue-700"
                />
                <span>Обновить файлы, если репозиторий с таким именем уже существует</span>
              </label>

              <button
                type="submit"
                disabled={publishing || !repoName.trim()}
                className="inline-flex items-center gap-2 h-10 px-5 text-sm font-medium bg-blue-700 text-white rounded-lg hover:bg-blue-800 disabled:opacity-50 whitespace-nowrap"
              >
                <UploadCloud className="w-4 h-4" />
                {publishing
                  ? 'Загрузка файлов на GitHub...'
                  : 'Загрузить на GitHub и собрать .exe'}
              </button>
            </div>
          </form>
        )}

        {publishResult && (
          <div className="p-4 bg-emerald-50 border border-emerald-200 rounded-lg space-y-3">
            <div className="text-sm font-semibold text-emerald-900">
              Проект успешно загружен на GitHub · {publishResult.filesCount} файлов в ветке {publishResult.defaultBranch}
            </div>
            <div className="text-xs text-emerald-800 font-mono">
              Коммит: {publishResult.commitSha.slice(0, 10)} · GitHub Actions уже начал компиляцию Windows x64 Portable.
            </div>
            <div className="flex flex-wrap items-center gap-3 pt-1">
              <a
                href={publishResult.actionsUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 px-3.5 py-2 text-xs font-medium bg-emerald-700 text-white rounded-lg hover:bg-emerald-800 whitespace-nowrap"
              >
                <ExternalLink className="w-3.5 h-3.5" />
                Открыть сборку в GitHub Actions
              </a>
              <a
                href={publishResult.repoUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 px-3.5 py-2 text-xs font-medium text-emerald-900 bg-white border border-emerald-300 rounded-lg hover:bg-emerald-100/50 whitespace-nowrap"
              >
                <ExternalLink className="w-3.5 h-3.5" />
                Открыть репозиторий
              </a>
            </div>
          </div>
        )}
      </section>

      {/* Alternative: Manual Git CLI steps */}
      <div className="bg-white border border-slate-200 rounded-xl divide-y divide-slate-200">
        <div className="p-6 space-y-2">
          <h2 className="text-base font-semibold text-slate-900">
            Альтернатива: загрузка вручную через ZIP и Git CLI
          </h2>
          <p className="text-sm text-slate-600 leading-relaxed max-w-3xl">
            Если вы не хотите настраивать OAuth App, просто скачайте ZIP-архив, распакуйте его и выполните команды ниже в папке проекта.
          </p>
        </div>

        <div className="p-6 space-y-3">
          <div className="flex items-center justify-between gap-3">
            <h3 className="text-sm font-semibold text-slate-900">
              01. Отправка файлов в ветку main
            </h3>
            <button
              type="button"
              onClick={() => copyText('git-init', gitInitSnippet)}
              className="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
            >
              {copiedId === 'git-init' ? (
                <>
                  <Check className="w-3.5 h-3.5 text-emerald-600" />
                  Скопировано
                </>
              ) : (
                <>
                  <Copy className="w-3.5 h-3.5" />
                  Копировать команды
                </>
              )}
            </button>
          </div>
          <pre className="p-4 bg-slate-950 text-slate-200 rounded-lg text-xs font-mono overflow-x-auto leading-relaxed">
            <code>{gitInitSnippet}</code>
          </pre>
        </div>

        <div className="p-6 space-y-3">
          <div className="flex items-center justify-between gap-3">
            <h3 className="text-sm font-semibold text-slate-900">
              02. Скачивание готового .exe из Actions или Releases
            </h3>
            {config.githubReleaseOnTag && (
              <button
                type="button"
                onClick={() => copyText('git-tag', gitTagSnippet)}
                className="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
              >
                {copiedId === 'git-tag' ? (
                  <>
                    <Check className="w-3.5 h-3.5 text-emerald-600" />
                    Скопировано
                  </>
                ) : (
                  <>
                    <Copy className="w-3.5 h-3.5" />
                    Тег для Release
                  </>
                )}
              </button>
            )}
          </div>
          <p className="text-sm text-slate-600 leading-relaxed max-w-3xl">
            После отправки файлов откройте вкладку <strong>Actions</strong> — через 3–5 минут в разделе <strong>Artifacts</strong> появится архив <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">{config.packageName}-portable-win64.zip</code>. Распакуйте его в любую папку и запустите <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">{config.packageName}.exe</code>.
          </p>
          {config.githubReleaseOnTag && (
            <pre className="p-3.5 bg-slate-950 text-slate-200 rounded-lg text-xs font-mono overflow-x-auto">
              <code>{gitTagSnippet}</code>
            </pre>
          )}
        </div>
      </div>

      {/* Technical reference table for Huawei E173 */}
      <section className="bg-white border border-slate-200 rounded-xl overflow-hidden">
        <div className="px-6 py-4 border-b border-slate-200">
          <h2 className="text-base font-semibold text-slate-900">
            Справочник портов Huawei E173 в Windows
          </h2>
          <p className="text-xs text-slate-500 mt-0.5">
            Для работы программы в Диспетчере устройств должны быть установлены драйверы Huawei Mobile Connect (VID_12D1).
          </p>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-xs font-medium text-slate-600">
                <th className="py-3 px-6">Интерфейс в Диспетчере устройств</th>
                <th className="py-3 px-4">USB ID (пример)</th>
                <th className="py-3 px-6">Назначение</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200 text-slate-700">
              <tr className="hover:bg-slate-50/70">
                <td className="py-3 px-6 font-medium text-slate-900">
                  HUAWEI Mobile Connect - 3G PC UI Interface
                </td>
                <td className="py-3 px-4 font-mono text-xs text-slate-600">
                  VID_12D1&amp;PID_1436&amp;MI_02
                </td>
                <td className="py-3 px-6 text-xs text-slate-600">
                  Основной управляющий COM-порт для AT-команд, SMS, USSD и сигнала. Работает параллельно с интернетом.
                </td>
              </tr>
              <tr className="hover:bg-slate-50/70">
                <td className="py-3 px-6 font-medium text-slate-900">
                  HUAWEI Mobile Connect - 3G Application Interface
                </td>
                <td className="py-3 px-4 font-mono text-xs text-slate-600">
                  VID_12D1&amp;PID_1436&amp;MI_01
                </td>
                <td className="py-3 px-6 text-xs text-slate-600">
                  Вспомогательный диагностический порт (запасной, если PC UI занят).
                </td>
              </tr>
              <tr className="hover:bg-slate-50/70">
                <td className="py-3 px-6 font-medium text-slate-900">
                  HUAWEI Mobile Connect - 3G Modem
                </td>
                <td className="py-3 px-4 font-mono text-xs text-slate-600">
                  VID_12D1&amp;PID_1436&amp;MI_00
                </td>
                <td className="py-3 px-6 text-xs text-slate-600">
                  Модемный канал для Dial-Up (rasdial.exe / *99#). Занимается системой во время сессии.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
};
