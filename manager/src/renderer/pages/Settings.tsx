import React from 'react';
import { useAppContext } from '../context/AppContext';
import type { Settings as ManagerSettings } from '../../shared/types';

export const Settings: React.FC = () => {
  const { settings, updateSettings, addLog } = useAppContext();

  const handleChange = <Key extends keyof ManagerSettings>(
    key: Key,
    value: ManagerSettings[Key],
  ) => {
    updateSettings({ [key]: value });
    addLog(`Changed setting ${key} to ${value}`);
  };

  return (
    <div className="max-w-4xl mx-auto space-y-8">
      <div>
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-white mb-1">Preferences</h2>
        <p className="text-sm text-neutral-500 dark:text-neutral-400">Configure update behaviors and application modes.</p>
      </div>

      <div className="bg-white dark:bg-black border border-neutral-200 dark:border-neutral-800 rounded-lg divide-y divide-neutral-100 dark:divide-neutral-800 transition-colors">

        <div className="p-5 flex items-center justify-between">
          <div>
            <div className="font-medium text-neutral-800 dark:text-neutral-100 text-sm">Update Checking</div>
            <div className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">How often to check for new project kernels.</div>
          </div>
          <select
            className="bg-neutral-50 dark:bg-black border border-neutral-300 dark:border-neutral-700 text-neutral-900 dark:text-white text-sm rounded-md focus:ring-black focus:border-black dark:focus:ring-white dark:focus:border-white block p-2 transition-colors"
            value={settings.updateFrequency}
            onChange={(e) => handleChange(
              'updateFrequency',
              e.target.value as ManagerSettings['updateFrequency'],
            )}
          >
            <option value="daily">Daily</option>
            <option value="weekly">Weekly</option>
            <option value="manual">Manual only</option>
          </select>
        </div>

        <div className="p-5 flex items-center justify-between">
          <div>
            <div className="font-medium text-neutral-800 dark:text-neutral-100 text-sm">Download Behavior</div>
            <div className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">When a new kernel is found.</div>
          </div>
          <select
            className="bg-neutral-50 dark:bg-black border border-neutral-300 dark:border-neutral-700 text-neutral-900 dark:text-white text-sm rounded-md focus:ring-black focus:border-black dark:focus:ring-white dark:focus:border-white block p-2 transition-colors"
            value={settings.downloadBehavior}
            onChange={(e) => handleChange(
              'downloadBehavior',
              e.target.value as ManagerSettings['downloadBehavior'],
            )}
          >
            <option value="auto">Download automatically</option>
            <option value="notify">Notify only</option>
          </select>
        </div>

        <div className="p-5 flex items-center justify-between">
          <div>
            <div className="font-medium text-neutral-800 dark:text-neutral-100 text-sm">Keep Old Project Kernels</div>
            <div className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">Number of old versions to retain for rollback.</div>
          </div>
          <select
            className="bg-neutral-50 dark:bg-black border border-neutral-300 dark:border-neutral-700 text-neutral-900 dark:text-white text-sm rounded-md focus:ring-black focus:border-black dark:focus:ring-white dark:focus:border-white block p-2 transition-colors"
            value={settings.keepProjectKernels}
            onChange={(e) => handleChange('keepProjectKernels', parseInt(e.target.value))}
          >
            <option value={1}>1 (Minimum)</option>
            <option value={2}>2 (Recommended)</option>
            <option value={3}>3</option>
          </select>
        </div>

        <div className="p-5 flex items-center justify-between">
          <div>
            <div className="font-medium text-neutral-800 dark:text-neutral-100 text-sm">Advanced Mode</div>
            <div className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">Expose underlying command logs, TPM PCR details, and manual overrides.</div>
          </div>
          <label className="relative inline-flex items-center cursor-pointer">
            <input
              type="checkbox"
              className="sr-only peer"
              checked={settings.advancedMode}
              onChange={(e) => handleChange('advancedMode', e.target.checked)}
            />
            <div className="w-11 h-6 bg-neutral-200 dark:bg-neutral-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-neutral-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-black dark:peer-checked:bg-white"></div>
          </label>
        </div>

      </div>
    </div>
  );
};
