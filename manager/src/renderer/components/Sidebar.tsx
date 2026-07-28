import React from 'react';
import type { LucideIcon } from 'lucide-react';

interface SidebarProps {
  items: { id: string; label: string; icon: LucideIcon }[];
  activeTab: string;
  onTabChange: (id: string) => void;
}

export const Sidebar: React.FC<SidebarProps> = ({ items, activeTab, onTabChange }) => {
  return (
    <div className="w-64 bg-white dark:bg-black border-r border-neutral-200 dark:border-neutral-800 flex flex-col h-full transition-colors duration-200">
      <div className="p-4 border-b border-neutral-200 dark:border-neutral-800">
        <h1 className="font-semibold text-neutral-800 dark:text-neutral-100 text-lg flex items-center gap-2">
          Secure Hibernate
        </h1>
      </div>
      <nav className="flex-1 overflow-y-auto p-3 space-y-1">
        {items.map((item) => {
          const Icon = item.icon;
          const isActive = activeTab === item.id;
          return (
            <button
              key={item.id}
              onClick={() => onTabChange(item.id)}
              className={`w-full flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors ${
                isActive
                  ? 'bg-neutral-200/70 dark:bg-neutral-800 text-neutral-900 dark:text-white'
                  : 'text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800/50 hover:text-neutral-900 dark:hover:text-white'
              }`}
            >
              <Icon size={18} className={isActive ? 'text-neutral-900 dark:text-white' : 'text-neutral-500 dark:text-neutral-500'} />
              {item.label}
            </button>
          );
        })}
      </nav>
      <div className="p-4 text-xs text-neutral-400 dark:text-neutral-500 border-t border-neutral-200 dark:border-neutral-800">
        v1.0.0-prototype
      </div>
    </div>
  );
};
