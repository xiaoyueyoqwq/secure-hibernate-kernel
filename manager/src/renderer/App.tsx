import React, { useState } from 'react';
import { Sidebar } from './components/Sidebar';
import { Overview } from './pages/Overview';
import { InstallationWizard } from './pages/InstallationWizard';
import { Kernels } from './pages/Kernels';
import { Security } from './pages/Security';
import { Settings } from './pages/Settings';
import { Diagnostics } from './pages/Diagnostics';
import { useAppContext } from './context/AppContext';
import { Activity, DownloadCloud, Shield, Settings as SettingsIcon, TerminalSquare, RefreshCw, AlertTriangle } from 'lucide-react';

export default function App() {
  const [activeTab, setActiveTab] = useState('overview');
  const { state, settings } = useAppContext();

  const NAV_ITEMS = [
    { id: 'overview', label: 'Overview', icon: Activity },
    { id: 'wizard', label: 'Installation Wizard', icon: DownloadCloud },
    { id: 'kernels', label: 'Kernels & Updates', icon: RefreshCw },
    { id: 'security', label: 'Security & TPM', icon: Shield },
    { id: 'settings', label: 'Preferences', icon: SettingsIcon },
  ];

  if (settings.advancedMode) {
    NAV_ITEMS.push({ id: 'diagnostics', label: 'Diagnostics', icon: TerminalSquare });
  }

  const renderContent = () => {
    switch (activeTab) {
      case 'overview': return <Overview />;
      case 'wizard': return <InstallationWizard />;
      case 'kernels': return <Kernels />;
      case 'security': return <Security />;
      case 'settings': return <Settings />;
      case 'diagnostics': return <Diagnostics />;
      default: return <Overview />;
    }
  };

  return (
    <div className="flex h-screen w-full bg-white dark:bg-black text-neutral-900 dark:text-white overflow-hidden font-sans transition-colors duration-200">
      <Sidebar
        items={NAV_ITEMS}
        activeTab={activeTab}
        onTabChange={setActiveTab}
      />
      <div className="flex-1 flex flex-col min-w-0">

        {/* Top Status Bar for Global App States */}
        {state === 'waiting-for-mok' && (
          <div className="bg-amber-50 dark:bg-amber-950/30 border-b border-amber-200 dark:border-amber-900/50 px-6 py-3 flex items-center justify-between">
            <div className="flex items-center gap-2 text-amber-800 dark:text-amber-400 text-sm font-medium">
              <AlertTriangle size={16} />
              <span>Pending MOK Enrollment: A reboot is required to enroll the project certificate.</span>
            </div>
          </div>
        )}

        {state === 'restart-required' && (
          <div className="bg-blue-50 dark:bg-blue-950/30 border-b border-blue-200 dark:border-blue-900/50 px-6 py-3 flex items-center justify-between">
            <div className="flex items-center gap-2 text-blue-800 dark:text-blue-400 text-sm font-medium">
              <RefreshCw size={16} className="animate-spin" />
              <span>Kernel updated successfully. A restart is required to apply changes.</span>
            </div>
          </div>
        )}

        <main className="flex-1 overflow-y-auto p-8">
          {renderContent()}
        </main>
      </div>
    </div>
  );
}
