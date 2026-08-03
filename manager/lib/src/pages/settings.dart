import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../translations.dart';
import '../widgets/app_select.dart';
import '../widgets/core.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: t.text('settings.title'),
          description: t.text('settings.description'),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('settings.appearance')),
        const SizedBox(height: 16),
        LabeledRow(
          title: t.text('settings.colorTheme'),
          description: t.text('settings.colorThemeDescription'),
          trailing: _ThemeControl(
            value: manager.themeMode,
            onChanged: manager.setThemeMode,
          ),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('settings.kernelMaintenance')),
        const SizedBox(height: 16),
        LabeledRow(
          title: t.text('settings.language'),
          description: t.text('settings.languageDescription'),
          trailing: AppSelect<AppLanguage>(
            value: manager.language,
            options: [
              AppSelectOption(AppLanguage.enUS, t.text('language.enUS')),
              AppSelectOption(AppLanguage.zhCN, t.text('language.zhCN')),
              AppSelectOption(AppLanguage.zhTW, t.text('language.zhTW')),
            ],
            onChanged: manager.setLanguage,
          ),
        ),
        const SizedBox(height: 12),
        LabeledRow(
          title: t.text('wizard.details.updatePolicy'),
          description: t.text('wizard.details.updatePolicyDescription'),
          trailing: AppSelect<UpdatePolicy>(
            value: manager.updatePolicy,
            options: [
              AppSelectOption(
                UpdatePolicy.manual,
                t.text('wizard.details.manualPolicy'),
              ),
              AppSelectOption(
                UpdatePolicy.checkAndNotify,
                t.text('wizard.details.notifyPolicy'),
              ),
              AppSelectOption(
                UpdatePolicy.automaticInstall,
                t.text('wizard.details.automaticPolicy'),
              ),
            ],
            disabled: manager.backendConnection == BackendConnection.loading ||
                manager.backendConnection == BackendConnection.error,
            onChanged: (value) {
              unawaited(manager.changeUpdatePolicy(value));
            },
          ),
        ),
        const SizedBox(height: 12),
        LabeledRow(
          title: t.text('settings.projectRollback'),
          description: t.text('wizard.details.kernelRetentionDescription'),
          trailing: AppSelect<int>(
            value: manager.projectKernelHistory,
            options: [
              AppSelectOption(1, t.text('settings.previousKernelOne')),
              for (final count in [2, 3])
                AppSelectOption(
                  count,
                  t.text('settings.previousKernelMany', {'count': '$count'}),
                ),
            ],
            disabled: manager.backendConnection == BackendConnection.loading ||
                manager.backendConnection == BackendConnection.error,
            onChanged: (value) {
              unawaited(manager.changeProjectKernelHistory(value));
            },
          ),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('settings.diagnostics')),
        const SizedBox(height: 16),
        LabeledRow(
          title: t.text('settings.advancedMode'),
          description: t.text('settings.advancedModeDescription'),
          trailing: Align(
            alignment: Alignment.centerRight,
            child: AppSwitch(
              value: manager.advancedMode,
              onChanged: manager.setAdvancedMode,
            ),
          ),
        ),
      ],
    );
  }
}

class _ThemeControl extends StatelessWidget {
  const _ThemeControl({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final values = [
      (ThemeMode.system, t.text('settings.system'), LucideIcons.monitor),
      (ThemeMode.light, t.text('settings.light'), LucideIcons.sun),
      (ThemeMode.dark, t.text('settings.dark'), LucideIcons.moon),
    ];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.palette.strongBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: values
            .map(
              (item) => _ThemeOption(
                controlKey: ValueKey('theme-${item.$1.name}'),
                label: item.$2,
                icon: item.$3,
                selected: item.$1 == value,
                onPressed: () => onChanged(item.$1),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.controlKey,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final Key controlKey;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        key: controlKey,
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minWidth: 80),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? palette.activeFill : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13,
                color: selected ? palette.activeText : palette.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? palette.activeText : palette.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
