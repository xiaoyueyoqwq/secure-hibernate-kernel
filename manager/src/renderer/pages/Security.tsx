import React from 'react';
import { useAppContext } from '../context/AppContext';
import { StatusRow } from '../components/StatusRow';
import { Shield, HardDrive } from 'lucide-react';

export const Security: React.FC = () => {
  const { systemStatus, addLog } = useAppContext();

  const handleEnrollMOK = () => addLog('Initiating MOK Enrollment preparation...');
  const handleBindTPM = () => addLog('Initiating TPM binding for LUKS...');

  return (
    <div className="max-w-4xl mx-auto space-y-8">
      <div>
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-white mb-1">Security & Hardware</h2>
        <p className="text-sm text-neutral-500 dark:text-neutral-400">Manage Secure Boot certificates and TPM policies.</p>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300 flex items-center gap-2">
          <Shield size={16} /> Secure Boot & MOK
        </h3>
        <div className="grid gap-3">
          <StatusRow
            label="Lockdown Mode"
            value={systemStatus.lockdown ? 'Enabled (Integrity)' : 'Disabled'}
            status={systemStatus.lockdown ? 'ok' : 'warning'}
            description="Restricts root from directly modifying kernel memory."
          />
          <StatusRow
            label="Project Certificate"
            value={systemStatus.projectCertEnrolled ? 'Enrolled in Firmware' : 'Missing'}
            status={systemStatus.projectCertEnrolled ? 'ok' : 'warning'}
            description="Allows loading the customized hibernate kernel."
            action={!systemStatus.projectCertEnrolled && (
              <button
                onClick={handleEnrollMOK}
                className="px-3 py-1.5 bg-black dark:bg-white hover:bg-neutral-800 dark:hover:bg-neutral-200 text-white dark:text-black text-xs font-medium rounded transition-colors"
              >
                Enroll Key
              </button>
            )}
          />
        </div>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-semibold text-neutral-700 dark:text-neutral-300 flex items-center gap-2">
          <HardDrive size={16} /> Disk Encryption (LUKS)
        </h3>
        <div className="grid gap-3">
          <StatusRow
            label="LUKS State"
            value={systemStatus.luks ? 'Encrypted' : 'Not Encrypted'}
            status={systemStatus.luks ? 'ok' : 'error'}
          />
          <StatusRow
            label="TPM Binding"
            value={systemStatus.tpmBound ? 'Bound (PCR 7)' : 'Not Bound'}
            status={systemStatus.tpmBound ? 'ok' : 'info'}
            description="Enables automatic unlock if Secure Boot state is trusted."
            action={
              <button
                onClick={handleBindTPM}
                className="px-3 py-1.5 bg-neutral-100 dark:bg-neutral-800 hover:bg-neutral-200 dark:hover:bg-neutral-700 text-neutral-800 dark:text-neutral-100 text-xs font-medium rounded transition-colors"
              >
                {systemStatus.tpmBound ? 'Re-bind' : 'Bind TPM'}
              </button>
            }
          />
        </div>
        <div className="text-xs text-neutral-500 dark:text-neutral-400 bg-neutral-50 dark:bg-black p-3 rounded border border-neutral-200 dark:border-neutral-800 transition-colors">
          <strong>Note:</strong> Always keep a backup of your LUKS recovery password. If the motherboard is replaced or Secure Boot state changes drastically, the TPM will not release the key.
        </div>
      </div>
    </div>
  );
};
