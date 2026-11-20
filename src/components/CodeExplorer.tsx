import React, { useMemo, useState } from 'react';
import { Check, Copy, Download, FileCode2, Search } from 'lucide-react';
import { GeneratedFile } from '../types/project';
import { downloadSingleFile } from '../utils/downloadZip';

interface CodeExplorerProps {
  files: GeneratedFile[];
}

export const CodeExplorer: React.FC<CodeExplorerProps> = ({ files }) => {
  const [selectedPath, setSelectedPath] = useState<string>(files[0]?.path || '');
  const [filter, setFilter] = useState<string>('');
  const [copiedPath, setCopiedPath] = useState<string | null>(null);

  const filteredFiles = useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!q) return files;
    return files.filter(
      (f) =>
        f.path.toLowerCase().includes(q) ||
        f.description.toLowerCase().includes(q) ||
        f.content.toLowerCase().includes(q)
    );
  }, [files, filter]);

  const activeFile =
    files.find((f) => f.path === selectedPath) || filteredFiles[0] || files[0];

  const lines = useMemo(
    () => (activeFile ? activeFile.content.split('\n') : []),
    [activeFile]
  );

  const handleCopy = async () => {
    if (!activeFile) return;
    try {
      await navigator.clipboard.writeText(activeFile.content);
      setCopiedPath(activeFile.path);
      window.setTimeout(() => setCopiedPath(null), 2000);
    } catch {
      // Clipboard fallback ignored
    }
  };

  const totalLines = useMemo(
    () => files.reduce((acc, f) => acc + f.content.split('\n').length, 0),
    [files]
  );

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-slate-900">
            Исходный код Flutter и GitHub Actions
          </h1>
          <p className="mt-1 text-sm text-slate-600 max-w-2xl">
            Полный комплект файлов репозитория. Нативный Win32 драйвер COM-порта написан на чистом dart:ffi, поэтому сборка на windows-latest не зависит от внешних C++ библиотек.
          </p>
        </div>
        <div className="flex items-center gap-2 text-xs text-slate-500 font-mono tabular-nums whitespace-nowrap">
          <span>{files.length} файлов</span>
          <span aria-hidden="true">·</span>
          <span>{totalLines} строк</span>
          <span aria-hidden="true">·</span>
          <span>Flutter 3.24+ / Dart 3</span>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-[290px_1fr] bg-white border border-slate-200 rounded-xl overflow-hidden min-h-[600px]">
        {/* File sidebar */}
        <div className="border-b lg:border-b-0 lg:border-r border-slate-200 bg-slate-50/70 flex flex-col">
          <div className="p-3 border-b border-slate-200">
            <div className="relative">
              <Search className="w-3.5 h-3.5 text-slate-400 absolute left-3 top-1/2 -translate-y-1/2" />
              <input
                type="search"
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="Поиск по файлам и коду..."
                className="w-full h-9 pl-8 pr-3 text-xs bg-white border border-slate-300 rounded-lg focus:outline-none focus:border-blue-600"
              />
            </div>
          </div>

          <div className="flex-1 overflow-y-auto p-2 space-y-0.5">
            {filteredFiles.length === 0 ? (
              <div className="p-4 text-xs text-slate-500 text-center">
                Совпадений не найдено.
              </div>
            ) : (
              filteredFiles.map((file) => {
                const isSelected = activeFile?.path === file.path;
                return (
                  <button
                    key={file.path}
                    type="button"
                    onClick={() => setSelectedPath(file.path)}
                    className={`w-full text-left px-3 py-2 rounded-lg transition-colors ${
                      isSelected
                        ? 'bg-blue-700 text-white'
                        : 'text-slate-700 hover:bg-slate-200/70'
                    }`}
                  >
                    <div className="flex items-center gap-2 min-w-0">
                      <FileCode2
                        className={`w-3.5 h-3.5 shrink-0 ${
                          isSelected ? 'text-blue-200' : 'text-slate-400'
                        }`}
                      />
                      <span className="text-xs font-mono truncate">
                        {file.path}
                      </span>
                    </div>
                  </button>
                );
              })
            )}
          </div>
        </div>

        {/* Code viewer */}
        {activeFile && (
          <div className="flex flex-col min-w-0">
            <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3.5 border-b border-slate-200 bg-white">
              <div className="min-w-0">
                <div className="text-sm font-mono font-semibold text-slate-900 truncate">
                  {activeFile.path}
                </div>
                <div className="text-xs text-slate-500 mt-0.5">
                  {activeFile.description} · {lines.length} строк
                </div>
              </div>

              <div className="flex items-center gap-2 shrink-0">
                <button
                  type="button"
                  onClick={handleCopy}
                  className="inline-flex items-center gap-1.5 h-8 px-3 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
                >
                  {copiedPath === activeFile.path ? (
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
                <button
                  type="button"
                  onClick={() => downloadSingleFile(activeFile)}
                  className="inline-flex items-center gap-1.5 h-8 px-3 text-xs font-medium text-slate-700 bg-white border border-slate-300 rounded-lg hover:bg-slate-50 whitespace-nowrap"
                >
                  <Download className="w-3.5 h-3.5" />
                  Файл
                </button>
              </div>
            </div>

            <div className="flex-1 overflow-auto bg-slate-950 text-slate-100 p-4 max-h-[580px]">
              <pre className="text-xs font-mono leading-relaxed">
                <code>
                  {lines.map((line, idx) => (
                    <div key={idx} className="flex hover:bg-slate-900/70">
                      <span className="w-11 pr-4 text-right select-none text-slate-600 shrink-0 tabular-nums">
                        {idx + 1}
                      </span>
                      <span className="whitespace-pre text-slate-200">{line}</span>
                    </div>
                  ))}
                </code>
              </pre>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
