export type AppState = 'idle' | 'installing' | 'waiting-for-mok' | 'restart-required' | 'error' | 'success';

export type KernelType = 'official' | 'project';
export type KernelStatus = 'active' | 'installed' | 'available';

export interface Kernel {
  id: string;
  version: string;
  type: KernelType;
  status: KernelStatus;
  releaseDate?: string;
}

export interface SystemStatus {
  ubuntuVersion: string;
  secureBoot: boolean;
  lockdown: boolean;
  luks: boolean;
  tpmBound: boolean;
  hibernatePartition: boolean;
  grubUpdated: boolean;
  projectCertEnrolled: boolean;
}

export interface Settings {
  updateFrequency: 'daily' | 'weekly' | 'manual';
  downloadBehavior: 'auto' | 'notify';
  installBehavior: 'auto' | 'notify';
  restartBehavior: 'notify';
  keepProjectKernels: number;
  keepOfficialKernels: boolean;
  advancedMode: boolean;
}

export interface AppContextType {
  state: AppState;
  setState: (state: AppState) => void;
  systemStatus: SystemStatus;
  setSystemStatus: (status: Partial<SystemStatus>) => void;
  kernels: Kernel[];
  settings: Settings;
  updateSettings: (settings: Partial<Settings>) => void;
  logs: string[];
  addLog: (log: string) => void;
}
