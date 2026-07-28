import React, { useState } from 'react';
import { useAppContext } from '../context/AppContext';
import { Check, ChevronRight, Loader2, AlertTriangle } from 'lucide-react';

const STEPS = [
  { id: 'check', title: 'Compatibility Check' },
  { id: 'download', title: 'Download Kernel' },
  { id: 'mok', title: 'Enroll MOK' },
  { id: 'install', title: 'Install & Config' },
  { id: 'done', title: 'Finish' }
];

export const InstallationWizard: React.FC = () => {
  const { state, setState, systemStatus, setSystemStatus, addLog } = useAppContext();
  const [currentStep, setCurrentStep] = useState(0);
  const [isProcessing, setIsProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const simulateProcess = async (time: number, successAction: () => void) => {
    setIsProcessing(true);
    setError(null);
    return new Promise<void>(resolve => {
      setTimeout(() => {
        setIsProcessing(false);
        successAction();
        resolve();
      }, time);
    });
  };

  const handleNext = async () => {
    switch (currentStep) {
      case 0: // Check
        addLog('Running compatibility checks...');
        await simulateProcess(1500, () => {
          if (!systemStatus.hibernatePartition) {
            setError('No suitable swap partition found.');
          } else {
            setCurrentStep(1);
          }
        });
        break;
      case 1: // Download
        addLog('Downloading latest project kernel release...');
        await simulateProcess(2000, () => setCurrentStep(2));
        break;
      case 2: // MOK
        addLog('Preparing MOK enrollment...');
        await simulateProcess(1500, () => {
          setState('waiting-for-mok');
          setSystemStatus({ projectCertEnrolled: true }); // Simulated after reboot
          setCurrentStep(3);
        });
        break;
      case 3: // Install
        if (state === 'waiting-for-mok') {
          // Simulate reboot completed
          setState('installing');
        }
        addLog('Installing kernel and configuring GRUB/Initramfs...');
        await simulateProcess(2500, () => {
          setState('success');
          setCurrentStep(4);
        });
        break;
      case 4: // Done
        setCurrentStep(0);
        setState('idle');
        break;
    }
  };

  return (
    <div className="max-w-3xl mx-auto">
      <div className="mb-8">
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-white">Installation Wizard</h2>
        <p className="text-sm text-neutral-500 dark:text-neutral-400">Guided setup for secure hibernation.</p>
      </div>

      <div className="flex mb-8">
        {STEPS.map((step, idx) => (
          <div key={step.id} className="flex-1 flex items-center">
            <div className={`flex flex-col items-center flex-1 ${idx <= currentStep ? 'text-neutral-900 dark:text-white' : 'text-neutral-400 dark:text-neutral-600'}`}>
              <div className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium border-2 transition-colors
                ${idx < currentStep ? 'bg-black border-black text-white dark:bg-white dark:border-white dark:text-black' :
                  idx === currentStep ? 'border-black text-black dark:border-white dark:text-white' : 'border-neutral-300 dark:border-neutral-700'}`}>
                {idx < currentStep ? <Check size={16} /> : idx + 1}
              </div>
              <span className="text-xs font-medium mt-2">{step.title}</span>
            </div>
            {idx < STEPS.length - 1 && (
              <div className={`h-px w-full -mt-5 transition-colors ${idx < currentStep ? 'bg-black dark:bg-white' : 'bg-neutral-200 dark:bg-neutral-800'}`} />
            )}
          </div>
        ))}
      </div>

      <div className="bg-white dark:bg-black border border-neutral-200 dark:border-neutral-800 rounded-lg p-6 min-h-[300px] flex flex-col transition-colors">
        <div className="flex-1">
          {error && (
            <div className="mb-4 p-4 bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900/50 flex items-start gap-3">
              <AlertTriangle size={20} className="shrink-0 mt-0.5" />
              <p className="text-sm">{error}</p>
            </div>
          )}

          {currentStep === 0 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium text-neutral-900 dark:text-white">System Compatibility</h3>
              <p className="text-sm text-neutral-600 dark:text-neutral-400">We will verify if your system meets the requirements (Secure Boot, Swap partition, LUKS setup).</p>
            </div>
          )}

          {currentStep === 1 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium text-neutral-900 dark:text-white">Download Kernel</h3>
              <p className="text-sm text-neutral-600 dark:text-neutral-400">Downloading the signed project kernel and verifying its signature against the release metadata.</p>
            </div>
          )}

          {currentStep === 2 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium text-neutral-900 dark:text-white">Machine Owner Key (MOK)</h3>
              <p className="text-sm text-neutral-600 dark:text-neutral-400">To boot the custom kernel with Secure Boot enabled, the project's public key must be enrolled in the firmware.</p>
              {state === 'waiting-for-mok' && (
                <div className="p-4 bg-amber-50 dark:bg-amber-950/30 text-amber-800 dark:text-amber-400 border border-amber-200 dark:border-amber-900/50 rounded-md text-sm">
                  <strong>Reboot Required:</strong> On next boot, you will see the MOK management screen. Choose "Enroll MOK" and enter the default password to continue.
                </div>
              )}
            </div>
          )}

          {currentStep === 3 && (
            <div className="space-y-4">
              <h3 className="text-lg font-medium text-neutral-900 dark:text-white">Install & Configure</h3>
              <p className="text-sm text-neutral-600 dark:text-neutral-400">Installing the kernel package, configuring initramfs with dracut, and updating GRUB.</p>
            </div>
          )}

          {currentStep === 4 && (
            <div className="space-y-4 text-center py-8">
              <div className="mx-auto w-16 h-16 bg-emerald-100 dark:bg-emerald-900/30 text-emerald-600 dark:text-emerald-400 rounded-full flex items-center justify-center mb-4">
                <Check size={32} />
              </div>
              <h3 className="text-xl font-medium text-neutral-900 dark:text-white">Setup Complete</h3>
              <p className="text-sm text-neutral-600 dark:text-neutral-400 max-w-md mx-auto">Your system is now configured for secure hibernation. You can manage updates from the Kernels tab.</p>
            </div>
          )}
        </div>

        <div className="pt-6 border-t border-neutral-100 dark:border-neutral-800 flex justify-end transition-colors">
          <button
            onClick={handleNext}
            disabled={isProcessing || error !== null}
            className="flex items-center gap-2 px-4 py-2 bg-black dark:bg-white hover:bg-neutral-800 dark:hover:bg-neutral-200 text-white dark:text-black text-sm font-medium rounded-md disabled:opacity-50 transition-colors"
          >
            {isProcessing && <Loader2 size={16} className="animate-spin" />}
            {currentStep === 4 ? 'Finish' : currentStep === 2 && state !== 'waiting-for-mok' ? 'Prepare MOK' : 'Continue'}
            {!isProcessing && currentStep < 4 && <ChevronRight size={16} />}
          </button>
        </div>
      </div>
    </div>
  );
};
