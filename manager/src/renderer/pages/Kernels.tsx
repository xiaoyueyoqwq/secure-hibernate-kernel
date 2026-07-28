import React from 'react';
import { useAppContext } from '../context/AppContext';
import { Download, Trash2, CheckCircle2, ShieldCheck, ShieldAlert } from 'lucide-react';

export const Kernels: React.FC = () => {
  const { kernels, addLog } = useAppContext();

  const activeKernel = kernels.find(k => k.status === 'active');

  const handleAction = (action: string, kernelId: string) => {
    addLog(`Requested ${action} on kernel ${kernelId}`);
    // Simulated action
  };

  return (
    <div className="max-w-4xl mx-auto space-y-8">
      <div>
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-white mb-1">Kernel Management</h2>
        <p className="text-sm text-neutral-500 dark:text-neutral-400">Manage installed kernels and apply updates securely.</p>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300 uppercase tracking-wider">Active Kernel</h3>
        {activeKernel ? (
          <div className="bg-black dark:bg-neutral-800 text-neutral-50 rounded-lg p-5 flex items-start gap-4 transition-colors">
            <div className="mt-1">
              {activeKernel.type === 'project' ? <ShieldCheck size={24} className="text-emerald-400" /> : <ShieldAlert size={24} className="text-amber-400" />}
            </div>
            <div>
              <div className="font-mono text-lg">{activeKernel.version}</div>
              <div className="text-sm text-neutral-400 mt-1">
                {activeKernel.type === 'project' ? 'Project Signed Kernel (Hibernate Supported)' : 'Official Ubuntu Kernel (Standard)'}
              </div>
            </div>
          </div>
        ) : (
          <div className="text-sm text-neutral-500 dark:text-neutral-400">No active kernel detected.</div>
        )}
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300 uppercase tracking-wider">Installed Kernels</h3>
        <div className="bg-white dark:bg-black border border-neutral-200 dark:border-neutral-800 rounded-lg divide-y divide-neutral-100 dark:divide-neutral-800 transition-colors">
          {kernels.filter(k => k.status !== 'available').map(k => (
            <div key={k.id} className="p-4 flex items-center justify-between">
              <div>
                <div className="font-mono text-neutral-800 dark:text-neutral-100 font-medium flex items-center gap-2">
                  {k.version}
                  {k.status === 'active' && <span className="bg-emerald-100 dark:bg-emerald-900/30 text-emerald-800 dark:text-emerald-400 text-xs px-2 py-0.5 rounded-full flex items-center gap-1"><CheckCircle2 size={12}/> Active</span>}
                </div>
                <div className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                  Type: {k.type === 'project' ? 'Project Custom' : 'Ubuntu Official'}
                </div>
              </div>
              {k.status !== 'active' && k.type === 'project' && (
                <button
                  onClick={() => handleAction('uninstall', k.id)}
                  className="p-2 text-neutral-400 hover:text-red-600 dark:hover:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/30 rounded-md transition-colors"
                  title="Remove Kernel"
                >
                  <Trash2 size={18} />
                </button>
              )}
            </div>
          ))}
        </div>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300 uppercase tracking-wider">Available Updates</h3>
        <div className="bg-white dark:bg-black border border-neutral-200 dark:border-neutral-800 rounded-lg divide-y divide-neutral-100 dark:divide-neutral-800 transition-colors">
          {kernels.filter(k => k.status === 'available').length > 0 ? (
            kernels.filter(k => k.status === 'available').map(k => (
              <div key={k.id} className="p-4 flex items-center justify-between">
                <div>
                  <div className="font-mono text-neutral-800 dark:text-neutral-100 font-medium">{k.version}</div>
                  <div className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                    Release Date: {k.releaseDate} | Verified Signature
                  </div>
                </div>
                <button
                  onClick={() => handleAction('install', k.id)}
                  className="flex items-center gap-2 px-3 py-1.5 bg-neutral-100 dark:bg-neutral-800 hover:bg-neutral-200 dark:hover:bg-neutral-700 text-neutral-800 dark:text-neutral-100 text-sm font-medium rounded-md transition-colors"
                >
                  <Download size={16} />
                  Install
                </button>
              </div>
            ))
          ) : (
            <div className="p-4 text-sm text-neutral-500 dark:text-neutral-400">System is up to date.</div>
          )}
        </div>
      </div>
    </div>
  );
};
