import React from 'react';
import { useAppContext } from '../context/AppContext';
import { Terminal, Download } from 'lucide-react';

export const Diagnostics: React.FC = () => {
  const { logs } = useAppContext();

  return (
    <div className="max-w-4xl mx-auto space-y-6 h-full flex flex-col">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-semibold text-neutral-900 dark:text-white mb-1">Diagnostics & Logs</h2>
          <p className="text-sm text-neutral-500 dark:text-neutral-400">System event history and troubleshooting tools.</p>
        </div>
        <button className="flex items-center gap-2 px-3 py-1.5 bg-neutral-100 dark:bg-neutral-800 hover:bg-neutral-200 dark:hover:bg-neutral-700 text-neutral-800 dark:text-neutral-100 text-sm font-medium rounded-md transition-colors">
          <Download size={16} />
          Export Report
        </button>
      </div>

      <div className="flex-1 bg-black dark:bg-black rounded-lg p-4 font-mono text-xs text-neutral-300 overflow-y-auto min-h-[400px]">
        <div className="flex items-center gap-2 mb-4 text-neutral-500 border-b border-neutral-700 pb-2">
          <Terminal size={14} />
          <span>Application Event Log</span>
        </div>
        <div className="space-y-1">
          {logs.map((log, i) => (
            <div key={i} className="leading-relaxed">
              {log.includes('Error') ? (
                <span className="text-red-400">{log}</span>
              ) : log.includes('Warning') ? (
                <span className="text-amber-400">{log}</span>
              ) : (
                <span>{log}</span>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
