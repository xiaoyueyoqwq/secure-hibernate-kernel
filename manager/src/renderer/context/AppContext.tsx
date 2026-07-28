import React, { createContext, useContext, useState } from 'react';
import type { ReactNode } from 'react';
import type { AppContextType, AppState, Kernel, SystemStatus, Settings } from '../../shared/types';

const defaultSystemStatus: SystemStatus = {
  ubuntuVersion: 'Ubuntu 24.04 LTS',
  secureBoot: true,
  lockdown: true,
  luks: true,
  tpmBound: false,
  hibernatePartition: true,
  grubUpdated: false,
  projectCertEnrolled: false,
};

const defaultKernels: Kernel[] = [
  { id: 'k-off-1', version: '6.8.0-31-generic', type: 'official', status: 'installed' },
  { id: 'k-off-2', version: '6.8.0-35-generic', type: 'official', status: 'active' },
  { id: 'k-proj-1', version: '6.8.0-hibernate-v1', type: 'project', status: 'available', releaseDate: '2024-05-10' },
  { id: 'k-proj-2', version: '6.8.0-hibernate-v2', type: 'project', status: 'available', releaseDate: '2024-06-01' },
];

const defaultSettings: Settings = {
  updateFrequency: 'daily',
  downloadBehavior: 'auto',
  installBehavior: 'notify',
  restartBehavior: 'notify',
  keepProjectKernels: 2,
  keepOfficialKernels: true,
  advancedMode: false,
};

const AppContext = createContext<AppContextType | undefined>(undefined);

export const AppProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const [state, setState] = useState<AppState>('idle');
  const [systemStatus, setSystemStatusState] = useState<SystemStatus>(defaultSystemStatus);
  const [kernels] = useState<Kernel[]>(defaultKernels);
  const [settings, setSettingsState] = useState<Settings>(defaultSettings);
  const [logs, setLogs] = useState<string[]>(['[System] Application initialized']);

  const setSystemStatus = (status: Partial<SystemStatus>) => {
    setSystemStatusState(prev => ({ ...prev, ...status }));
  };

  const updateSettings = (newSettings: Partial<Settings>) => {
    setSettingsState(prev => ({ ...prev, ...newSettings }));
  };

  const addLog = (log: string) => {
    setLogs(prev => [...prev, `[${new Date().toLocaleTimeString()}] ${log}`]);
  };

  return (
    <AppContext.Provider value={{
      state, setState,
      systemStatus, setSystemStatus,
      kernels, settings, updateSettings,
      logs, addLog
    }}>
      {children}
    </AppContext.Provider>
  );
};

export const useAppContext = () => {
  const context = useContext(AppContext);
  if (context === undefined) {
    throw new Error('useAppContext must be used within an AppProvider');
  }
  return context;
};
