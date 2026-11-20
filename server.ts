import 'dotenv/config';
import crypto from 'crypto';
import express, { Request, Response } from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import { createServer as createViteServer } from 'vite';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

interface GitHubUser {
  login: string;
  name: string | null;
  avatar_url: string;
  html_url: string;
}

interface SessionRecord {
  accessToken: string;
  user: GitHubUser;
  createdAt: number;
}

interface StateRecord {
  createdAt: number;
}

const SESSION_TTL_MS = 1000 * 60 * 60 * 4; // 4 hours
const STATE_TTL_MS = 1000 * 60 * 10; // 10 minutes

const sessions = new Map<string, SessionRecord>();
const oauthStates = new Map<string, StateRecord>();

function cleanupExpired() {
  const now = Date.now();
  for (const [k, v] of sessions.entries()) {
    if (now - v.createdAt > SESSION_TTL_MS) sessions.delete(k);
  }
  for (const [k, v] of oauthStates.entries()) {
    if (now - v.createdAt > STATE_TTL_MS) oauthStates.delete(k);
  }
}

function getAppBaseUrl(): string {
  const raw = (process.env.APP_URL || 'http://localhost:3000').trim();
  return raw.replace(/\/+$/, '');
}

function getRedirectUri(): string {
  return `${getAppBaseUrl()}/auth/callback`;
}

function getGitHubCredentials(): { clientId: string; clientSecret: string } | null {
  const clientId = (process.env.GITHUB_CLIENT_ID || '').trim();
  const clientSecret = (process.env.GITHUB_CLIENT_SECRET || '').trim();
  if (!clientId || !clientSecret) return null;
  return { clientId, clientSecret };
}

function extractBearerSession(req: Request): SessionRecord | null {
  cleanupExpired();
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) return null;
  const token = auth.slice(7).trim();
  if (!token) return null;
  return sessions.get(token) || null;
}

function safeJsonForScript(obj: unknown): string {
  return JSON.stringify(obj).replace(/</g, '\\u003c').replace(/>/g, '\\u003e');
}

async function githubApi(
  accessToken: string,
  endpoint: string,
  options: { method?: string; body?: unknown } = {}
): Promise<{ status: number; data: Record<string, unknown> }> {
  const res = await fetch(`https://api.github.com${endpoint}`, {
    method: options.method || 'GET',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${accessToken}`,
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'Huawei-E173-Flutter-Builder',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

  const text = await res.text();
  let data: Record<string, unknown> = {};
  try {
    data = text ? (JSON.parse(text) as Record<string, unknown>) : {};
  } catch {
    data = { message: text };
  }
  return { status: res.status, data };
}

function isSafeRepoPath(filePath: string): boolean {
  if (!filePath || filePath.length > 200) return false;
  if (filePath.startsWith('/') || filePath.startsWith('\\')) return false;
  if (filePath.includes('..') || filePath.includes('\\')) return false;
  return /^[a-zA-Z0-9._\-/]+$/.test(filePath);
}

async function startServer() {
  const app = express();
  const PORT = 3000;

  app.use(express.json({ limit: '4mb' }));

  // 1. Status & OAuth configuration endpoint
  app.get('/api/github/status', (req: Request, res: Response) => {
    const creds = getGitHubCredentials();
    const session = extractBearerSession(req);
    res.json({
      configured: Boolean(creds),
      callbackUrl: getRedirectUri(),
      authenticated: Boolean(session),
      user: session ? session.user : null,
    });
  });

  // 2. Construct GitHub OAuth authorization URL (popup opens provider URL directly)
  app.get('/api/github/auth-url', (_req: Request, res: Response) => {
    cleanupExpired();
    const creds = getGitHubCredentials();
    if (!creds) {
      res.status(503).json({
        error:
          'На сервере не настроены секреты GITHUB_CLIENT_ID и GITHUB_CLIENT_SECRET.',
      });
      return;
    }

    const state = crypto.randomBytes(24).toString('hex');
    oauthStates.set(state, { createdAt: Date.now() });

    const params = new URLSearchParams({
      client_id: creds.clientId,
      redirect_uri: getRedirectUri(),
      scope: 'repo workflow',
      state,
    });

    res.json({
      url: `https://github.com/login/oauth/authorize?${params.toString()}`,
    });
  });

  // 3. GitHub OAuth callback (handles trailing slash too)
  const callbackHandler = async (req: Request, res: Response) => {
    cleanupExpired();
    const code = typeof req.query.code === 'string' ? req.query.code : '';
    const state = typeof req.query.state === 'string' ? req.query.state : '';
    const oauthError =
      typeof req.query.error_description === 'string'
        ? req.query.error_description
        : typeof req.query.error === 'string'
        ? req.query.error
        : '';

    const sendPopupResult = (payload: Record<string, unknown>, message: string) => {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.send(`<!doctype html>
<html lang="ru">
  <head><meta charset="utf-8"><title>GitHub OAuth</title></head>
  <body style="font-family:system-ui,sans-serif;padding:24px;color:#0f172a;">
    <p>${message}</p>
    <script>
      (function () {
        var payload = ${safeJsonForScript(payload)};
        if (window.opener) {
          window.opener.postMessage(payload, '*');
          window.close();
        }
      })();
    </script>
  </body>
</html>`);
    };

    if (oauthError) {
      sendPopupResult(
        { type: 'GITHUB_OAUTH_ERROR', error: oauthError },
        'Авторизация отклонена. Это окно можно закрыть.'
      );
      return;
    }

    if (!code || !state || !oauthStates.has(state)) {
      sendPopupResult(
        {
          type: 'GITHUB_OAUTH_ERROR',
          error: 'Недействительный или устаревший параметр state OAuth.',
        },
        'Ошибка проверки безопасности OAuth. Закройте окно и попробуйте снова.'
      );
      return;
    }
    oauthStates.delete(state);

    const creds = getGitHubCredentials();
    if (!creds) {
      sendPopupResult(
        {
          type: 'GITHUB_OAUTH_ERROR',
          error: 'GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET не настроены.',
        },
        'OAuth-секреты не настроены.'
      );
      return;
    }

    try {
      const tokenRes = await fetch('https://github.com/login/oauth/access_token', {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          client_id: creds.clientId,
          client_secret: creds.clientSecret,
          code,
          redirect_uri: getRedirectUri(),
        }),
      });

      const tokenJson = (await tokenRes.json()) as {
        access_token?: string;
        error?: string;
        error_description?: string;
      };

      if (!tokenJson.access_token) {
        sendPopupResult(
          {
            type: 'GITHUB_OAUTH_ERROR',
            error:
              tokenJson.error_description ||
              tokenJson.error ||
              'Не удалось получить токен GitHub.',
          },
          'Не удалось завершить вход в GitHub.'
        );
        return;
      }

      const userRes = await githubApi(tokenJson.access_token, '/user');
      if (userRes.status !== 200 || typeof userRes.data.login !== 'string') {
        sendPopupResult(
          {
            type: 'GITHUB_OAUTH_ERROR',
            error: 'Не удалось прочитать профиль пользователя GitHub.',
          },
          'Ошибка чтения профиля GitHub.'
        );
        return;
      }

      const user: GitHubUser = {
        login: userRes.data.login,
        name: typeof userRes.data.name === 'string' ? userRes.data.name : null,
        avatar_url:
          typeof userRes.data.avatar_url === 'string'
            ? userRes.data.avatar_url
            : '',
        html_url:
          typeof userRes.data.html_url === 'string' ? userRes.data.html_url : '',
      };

      const sessionToken = crypto.randomBytes(32).toString('hex');
      sessions.set(sessionToken, {
        accessToken: tokenJson.access_token,
        user,
        createdAt: Date.now(),
      });

      sendPopupResult(
        { type: 'GITHUB_OAUTH_SUCCESS', sessionToken, user },
        'Вход в GitHub выполнен. Это окно закроется автоматически.'
      );
    } catch {
      sendPopupResult(
        {
          type: 'GITHUB_OAUTH_ERROR',
          error: 'Сетевая ошибка при обмене кода OAuth с GitHub.',
        },
        'Ошибка соединения с GitHub.'
      );
    }
  };

  app.get(['/auth/callback', '/auth/callback/'], callbackHandler);

  // 4. Disconnect GitHub session
  app.post('/api/github/disconnect', (req: Request, res: Response) => {
    const auth = req.headers.authorization;
    if (auth && auth.startsWith('Bearer ')) {
      sessions.delete(auth.slice(7).trim());
    }
    res.json({ ok: true });
  });

  // 5. Create (or update) GitHub repo & push all generated Flutter + Workflow files in 1 atomic commit
  app.post('/api/github/publish', async (req: Request, res: Response) => {
    const session = extractBearerSession(req);
    if (!session) {
      res.status(401).json({
        error: 'Сначала подключите аккаунт GitHub.',
      });
      return;
    }

    const body = req.body as {
      repoName?: unknown;
      description?: unknown;
      isPrivate?: unknown;
      overwriteExisting?: unknown;
      files?: unknown;
    };

    const repoName =
      typeof body.repoName === 'string' ? body.repoName.trim() : '';
    if (!/^[a-zA-Z0-9._-]{1,100}$/.test(repoName)) {
      res.status(400).json({
        error:
          'Некорректное имя репозитория. Используйте латинские буквы, цифры, дефис или подчёркивание.',
      });
      return;
    }

    const description =
      typeof body.description === 'string'
        ? body.description.trim().slice(0, 250)
        : 'Portable Windows Flutter app for Huawei E173 modem';
    const isPrivate = Boolean(body.isPrivate);
    const overwriteExisting = Boolean(body.overwriteExisting);

    if (!Array.isArray(body.files) || body.files.length === 0 || body.files.length > 35) {
      res.status(400).json({ error: 'Передан некорректный список файлов.' });
      return;
    }

    const validatedFiles: { path: string; content: string }[] = [];
    for (const item of body.files) {
      if (
        !item ||
        typeof item !== 'object' ||
        typeof (item as { path?: unknown }).path !== 'string' ||
        typeof (item as { content?: unknown }).content !== 'string'
      ) {
        res.status(400).json({ error: 'Неверная структура файла в запросе.' });
        return;
      }
      const p = (item as { path: string }).path;
      const c = (item as { content: string }).content;
      if (!isSafeRepoPath(p) || c.length > 512_000) {
        res.status(400).json({ error: `Недопустимый путь или размер файла: ${p}` });
        return;
      }
      validatedFiles.push({ path: p, content: c });
    }

    const token = session.accessToken;
    const owner = session.user.login;

    try {
      // Step A: Create repo or verify existing repo
      let defaultBranch = 'main';
      let repoHtmlUrl = `https://github.com/${owner}/${repoName}`;

      const createRes = await githubApi(token, '/user/repos', {
        method: 'POST',
        body: {
          name: repoName,
          description,
          private: isPrivate,
          auto_init: true,
        },
      });

      if (createRes.status === 201) {
        if (typeof createRes.data.default_branch === 'string') {
          defaultBranch = createRes.data.default_branch;
        }
        if (typeof createRes.data.html_url === 'string') {
          repoHtmlUrl = createRes.data.html_url;
        }
      } else if (createRes.status === 422 && overwriteExisting) {
        const existingRes = await githubApi(token, `/repos/${owner}/${repoName}`);
        if (existingRes.status !== 200) {
          res.status(400).json({
            error: `Репозиторий ${owner}/${repoName} уже существует, но недоступен для обновления.`,
          });
          return;
        }
        if (typeof existingRes.data.default_branch === 'string') {
          defaultBranch = existingRes.data.default_branch;
        }
        if (typeof existingRes.data.html_url === 'string') {
          repoHtmlUrl = existingRes.data.html_url;
        }
      } else {
        const ghMsg =
          typeof createRes.data.message === 'string'
            ? createRes.data.message
            : 'Не удалось создать репозиторий на GitHub.';
        res.status(createRes.status === 422 ? 409 : 400).json({
          error:
            createRes.status === 422
              ? `Репозиторий «${repoName}» уже существует. Укажите другое имя или включите обновление существующего.`
              : `Ошибка GitHub API: ${ghMsg}`,
        });
        return;
      }

      // Step B: Get HEAD ref (retry briefly if auto_init just finished)
      let headCommitSha = '';
      for (let attempt = 0; attempt < 5; attempt++) {
        const refRes = await githubApi(
          token,
          `/repos/${owner}/${repoName}/git/ref/heads/${encodeURIComponent(defaultBranch)}`
        );
        const obj = refRes.data.object as { sha?: string } | undefined;
        if (refRes.status === 200 && obj?.sha) {
          headCommitSha = obj.sha;
          break;
        }
        await new Promise((r) => setTimeout(r, 700));
      }

      if (!headCommitSha) {
        res.status(502).json({
          error:
            'Репозиторий создан, но ветка main ещё инициализируется. Повторите отправку через пару секунд с галочкой «Обновить существующий».',
        });
        return;
      }

      // Step C: Get base tree SHA from HEAD commit
      const commitRes = await githubApi(
        token,
        `/repos/${owner}/${repoName}/git/commits/${headCommitSha}`
      );
      const baseTreeSha = (commitRes.data.tree as { sha?: string } | undefined)?.sha;
      if (!baseTreeSha) {
        res.status(502).json({ error: 'Не удалось получить базовое дерево коммита.' });
        return;
      }

      // Step D: Create blobs & build tree entries
      const treeEntries: {
        path: string;
        mode: string;
        type: string;
        sha: string;
      }[] = [];

      for (const file of validatedFiles) {
        const blobRes = await githubApi(token, `/repos/${owner}/${repoName}/git/blobs`, {
          method: 'POST',
          body: {
            content: Buffer.from(file.content, 'utf8').toString('base64'),
            encoding: 'base64',
          },
        });
        if (blobRes.status !== 201 || typeof blobRes.data.sha !== 'string') {
          res.status(502).json({
            error: `Ошибка загрузки файла ${file.path} в GitHub.`,
          });
          return;
        }
        treeEntries.push({
          path: file.path,
          mode: '100644',
          type: 'blob',
          sha: blobRes.data.sha,
        });
      }

      // Step E: Create tree
      const treeRes = await githubApi(token, `/repos/${owner}/${repoName}/git/trees`, {
        method: 'POST',
        body: {
          base_tree: baseTreeSha,
          tree: treeEntries,
        },
      });
      if (treeRes.status !== 201 || typeof treeRes.data.sha !== 'string') {
        res.status(502).json({ error: 'Не удалось создать Git tree на GitHub.' });
        return;
      }

      // Step F: Create atomic commit
      const newCommitRes = await githubApi(
        token,
        `/repos/${owner}/${repoName}/git/commits`,
        {
          method: 'POST',
          body: {
            message: 'Upload portable Flutter Windows project for Huawei E173',
            tree: treeRes.data.sha,
            parents: [headCommitSha],
          },
        }
      );
      if (newCommitRes.status !== 201 || typeof newCommitRes.data.sha !== 'string') {
        res.status(502).json({ error: 'Не удалось создать коммит на GitHub.' });
        return;
      }

      // Step G: Fast-forward branch ref
      const updateRefRes = await githubApi(
        token,
        `/repos/${owner}/${repoName}/git/refs/heads/${encodeURIComponent(defaultBranch)}`,
        {
          method: 'PATCH',
          body: {
            sha: newCommitRes.data.sha,
            force: false,
          },
        }
      );

      if (updateRefRes.status !== 200) {
        const msg =
          typeof updateRefRes.data.message === 'string'
            ? updateRefRes.data.message
            : 'Ошибка обновления ветки (проверьте права workflow в OAuth).';
        res.status(403).json({ error: msg });
        return;
      }

      res.json({
        repoUrl: repoHtmlUrl,
        actionsUrl: `${repoHtmlUrl}/actions`,
        commitSha: newCommitRes.data.sha,
        defaultBranch,
        filesCount: validatedFiles.length,
      });
    } catch {
      res.status(500).json({
        error: 'Внутренняя ошибка при публикации репозитория на GitHub.',
      });
    }
  });

  // Mount Vite middleware in dev, or serve static dist in production
  if (process.env.NODE_ENV !== 'production') {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'spa',
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.resolve(__dirname, 'dist');
    app.use(express.static(distPath));
    app.get('*', (_req, res) => {
      res.sendFile(path.join(distPath, 'index.html'));
    });
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server running on http://0.0.0.0:${PORT}`);
  });
}

startServer();
