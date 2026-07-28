import React from 'react';
import { useAppContext } from '../context/AppContext';
import { StatusRow } from '../components/StatusRow';

export const Overview: React.FC = () => {
  const { systemStatus, kernels } = useAppContext();

  const activeKernel = kernels.find(k => k.status === 'active')?.version || 'Unknown';
  const hasProjectKernel = kernels.some(k => k.type === 'project' && k.status !== 'available');

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      <div>
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-white mb-1">System Overview</h2>
        <p className="text-sm text-neutral-500 dark:text-neutral-400">Current status of your system's security and hibernate capabilities.</p>
      </div>

      <div className="grid gap-3">
        <StatusRow
          label="OS Version"
          value={systemStatus.ubuntuVersion}
          status="info"
        />

        <StatusRow
          label="Current Kernel"
          value={activeKernel}
          status={activeKernel.includes('hibernate') ? 'ok' : 'warning'}
          description={activeKernel.includes('hibernate') ? 'Running a secured hibernate-enabled kernel.' : 'Running official kernel. Hibernate may not be fully secured.'}
        />

        <StatusRow
          label="Secure Boot"
          value={systemStatus.secureBoot ? 'Enabled' : 'Disabled'}
          status={systemStatus.secureBoot ? 'ok' : 'error'}
          description="Ensures only trusted kernels are booted."
        />

        <StatusRow
          label="Project MOK"
          value={systemStatus.projectCertEnrolled ? 'Enrolled' : 'Not Enrolled'}
          status={systemStatus.projectCertEnrolled ? 'ok' : 'warning'}
          description="Required to boot project-signed kernels."
        />

        <StatusRow
          label="TPM Bound"
          value={systemStatus.tpmBound ? 'Yes' : 'No'}
          status={systemStatus.tpmBound ? 'ok' : 'info'}
          description="Uses TPM for automatic LUKS decryption (optional but recommended)."
        />

        <StatusRow
          label="Hibernate Partition"
          value={systemStatus.hibernatePartition ? 'Detected' : 'Missing'}
          status={systemStatus.hibernatePartition ? 'ok' : 'error'}
          description="Adequate swap space found for hibernation."
        />
      </div>

      {!hasProjectKernel && (
        <div className="bg-blue-50 dark:bg-blue-950/30 border border-blue-200 dark:border-blue-900/50 rounded-md p-4 flex items-start gap-3 transition-colors">
          <div className="text-blue-700 dark:text-blue-400 font-medium">Ready to Install</div>
          <p className="text-sm text-blue-800 dark:text-blue-300 flex-1">
            Your system appears compatible. Head over to the Installation Wizard to set up secure hibernation.
          </p>
        </div>
      )}
    </div>
  );
};
