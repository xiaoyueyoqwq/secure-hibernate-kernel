import React from 'react';
import { CheckCircle2, XCircle, AlertCircle, Info } from 'lucide-react';

interface StatusRowProps {
  label: string;
  value: React.ReactNode;
  status: 'ok' | 'error' | 'warning' | 'info';
  description?: string;
  action?: React.ReactNode;
}

export const StatusRow: React.FC<StatusRowProps> = ({ label, value, status, description, action }) => {
  const getIcon = () => {
    switch (status) {
      case 'ok': return <CheckCircle2 size={18} className="text-emerald-600" />;
      case 'error': return <XCircle size={18} className="text-red-600" />;
      case 'warning': return <AlertCircle size={18} className="text-amber-500" />;
      case 'info': return <Info size={18} className="text-blue-500" />;
    }
  };

  return (
    <div className="py-3 px-4 border border-neutral-200 dark:border-neutral-800 rounded-md bg-white dark:bg-black flex items-center justify-between gap-4 transition-colors">
      <div className="flex items-start gap-3 flex-1">
        <div className="mt-0.5">{getIcon()}</div>
        <div>
          <div className="flex items-center gap-2">
            <span className="font-medium text-neutral-800 dark:text-neutral-100">{label}:</span>
            <span className="text-neutral-700 dark:text-neutral-300">{value}</span>
          </div>
          {description && (
            <p className="text-sm text-neutral-500 dark:text-neutral-400 mt-1">{description}</p>
          )}
        </div>
      </div>
      {action && (
        <div className="flex-shrink-0">
          {action}
        </div>
      )}
    </div>
  );
};
