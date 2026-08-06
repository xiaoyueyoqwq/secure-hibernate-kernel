import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../widgets/core.dart';

class KernelsPage extends StatefulWidget {
  const KernelsPage({super.key});

  @override
  State<KernelsPage> createState() => _KernelsPageState();
}

class _KernelsPageState extends State<KernelsPage> {
  String? pendingRemoval;
  String? busyRelease;

  Future<void> removeKernel(KernelInfo kernel) async {
    final manager = context.manager;
    if (pendingRemoval != kernel.version) {
      setState(() => pendingRemoval = kernel.version);
      return;
    }
    if (!manager.native) {
      manager.addLog('Requested uninstall on kernel ${kernel.version}');
      setState(() => pendingRemoval = null);
      return;
    }
    setState(() => busyRelease = kernel.version);
    final result = await manager.runManagerAction(
      ManagerActionRequest(
        ManagerActionType.removeKernel,
        release: kernel.version,
      ),
    );
    if (result.status == ManagerActionStatus.success) {
      await manager.refreshSnapshot();
    }
    if (!mounted) return;
    setState(() {
      busyRelease = null;
      pendingRemoval = null;
    });
  }

  Future<void> installKernel(KernelInfo kernel) async {
    final manager = context.manager;
    if (!manager.native) {
      manager.addLog('Requested install on kernel ${kernel.version}');
      return;
    }
    setState(() => busyRelease = kernel.version);
    final result = await manager.runManagerAction(
      const ManagerActionRequest(ManagerActionType.installUpdate),
    );
    if (result.status == ManagerActionStatus.success) {
      await manager.refreshSnapshot();
    }
    if (!mounted) return;
    setState(() => busyRelease = null);
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    final active = manager.activeKernel;
    final pendingKernel = manager.updater.rebootRequired
        ? manager.kernels
            .where(
              (kernel) =>
                  kernel.status == KernelStatus.installed &&
                  kernel.version == manager.updater.installedKernelRelease,
            )
            .firstOrNull
        : null;
    final installed = manager.kernels
        .where(
          (kernel) =>
              kernel.status == KernelStatus.installed &&
              kernel.version != pendingKernel?.version,
        )
        .toList();
    final available = manager.kernels
        .where((kernel) => kernel.status == KernelStatus.available)
        .toList();
    final unavailable =
        manager.backendConnection == BackendConnection.loading ||
            manager.backendConnection == BackendConnection.error;
    final kernelReleaseChecking = manager.updater.checkServiceActive;
    final managerUpdate = manager.managerUpdate;
    final managerUpdateValue = switch (managerUpdate.state) {
      ManagerUpdateState.current => t.text('kernels.upToDate'),
      ManagerUpdateState.available => t.text('kernels.managerUpdateAvailable'),
      ManagerUpdateState.checking => t.text('kernels.managerUpdateChecking'),
      ManagerUpdateState.error => t.text('kernels.managerUpdateFailed'),
      ManagerUpdateState.unknown => t.text('kernels.managerUpdateNotChecked'),
    };
    final managerUpdateStatus = switch (managerUpdate.state) {
      ManagerUpdateState.current => StatusKind.ok,
      ManagerUpdateState.available => StatusKind.warning,
      ManagerUpdateState.checking => StatusKind.loading,
      ManagerUpdateState.error => StatusKind.error,
      ManagerUpdateState.unknown => StatusKind.pending,
    };
    final managerUpdateDescription = switch (managerUpdate.state) {
      ManagerUpdateState.current =>
        t.text('kernels.managerUpdateCurrentDescription', {
          'version': managerUpdate.currentVersion,
        }),
      ManagerUpdateState.available =>
        t.text('kernels.managerUpdateAvailableDescription', {
          'version': managerUpdate.latestVersion ?? '-',
          'current': managerUpdate.currentVersion,
        }),
      ManagerUpdateState.checking =>
        t.text('kernels.managerUpdateCheckingDescription'),
      ManagerUpdateState.error => t.text(
          'kernels.managerUpdateFailedDescription',
          {'error': managerUpdate.error ?? '-'},
        ),
      ManagerUpdateState.unknown =>
        t.text('kernels.managerUpdateNotCheckedDescription'),
    };
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: pendingRemoval == null
          ? null
          : () => setState(() => pendingRemoval = null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: t.text('kernels.title'),
            description: t.text('kernels.description'),
          ),
          const SizedBox(height: 32),
          SectionTitle(t.text('kernels.runningKernel')),
          const SizedBox(height: 16),
          StatusRow(
            label: t.text('kernels.activeVersion'),
            value: active.version.isEmpty
                ? Text(t.text('kernels.notDetected'))
                : Text(
                    active.version,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
            status: active.version.isEmpty
                ? StatusKind.error
                : active.project
                    ? StatusKind.ok
                    : StatusKind.warning,
            description: active.version.isEmpty
                ? t.text('kernels.notDetectedDescription')
                : active.project
                    ? t.text('kernels.projectActive')
                    : t.text('kernels.officialActive'),
          ),
          if (pendingKernel != null) ...[
            const SizedBox(height: 32),
            SectionTitle(t.text('kernels.pendingRestart')),
            const SizedBox(height: 16),
            StatusRow(
              key: ValueKey('pending-kernel-${pendingKernel.version}'),
              label: t.text('kernels.nextBootKernel'),
              value: Text(
                pendingKernel.version,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                ),
              ),
              status: StatusKind.warning,
              description: t.text('kernels.pendingRestartDescription'),
            ),
          ],
          const SizedBox(height: 32),
          SectionTitle(t.text('kernels.installedFallbacks')),
          const SizedBox(height: 16),
          for (var index = 0; index < installed.length; index++) ...[
            StatusRow(
              key: ValueKey('fallback-kernel-${installed[index].version}'),
              label: installed[index].project
                  ? t.text('kernels.projectKernel')
                  : t.text('kernels.ubuntuKernel'),
              value: Text(
                installed[index].version,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
              status: StatusKind.ok,
              description: installed[index].project
                  ? t.text('kernels.projectFallbackDescription')
                  : t.text('kernels.ubuntuFallbackDescription'),
              action: installed[index].project
                  ? AppButton(
                      label: pendingRemoval == installed[index].version
                          ? t.text('common.confirmRemoval')
                          : '',
                      width: pendingRemoval == installed[index].version
                          ? null
                          : 32,
                      height: 32,
                      icon: LucideIcons.trash2,
                      tone: pendingRemoval == installed[index].version
                          ? ButtonTone.danger
                          : ButtonTone.ghost,
                      selected: pendingRemoval == installed[index].version,
                      busy: busyRelease == installed[index].version,
                      disabled: unavailable || busyRelease != null,
                      onPressed: () => removeKernel(installed[index]),
                    )
                  : null,
            ),
            if (index != installed.length - 1) const SizedBox(height: 12),
          ],
          const SizedBox(height: 32),
          SectionTitle(t.text('kernels.availableUpdates')),
          const SizedBox(height: 16),
          StatusRow(
            key: const ValueKey('manager-software-update'),
            label: t.text('kernels.managerSoftware'),
            value: Text(managerUpdateValue),
            status: managerUpdateStatus,
            description: managerUpdateDescription,
            action: managerUpdate.state == ManagerUpdateState.available &&
                    managerUpdate.releaseUrl != null
                ? AppButton(
                    label: t.text('common.update'),
                    icon: LucideIcons.download,
                    onPressed: manager.openManagerUpdateRelease,
                  )
                : null,
          ),
          const SizedBox(height: 12),
          if (available.isEmpty)
            StatusRow(
              key: const ValueKey('kernel-release-status'),
              label: t.text('kernels.releaseStatus'),
              value: Text(t.text(
                kernelReleaseChecking
                    ? 'common.checkingStatus'
                    : 'kernels.upToDate',
              )),
              status:
                  kernelReleaseChecking ? StatusKind.loading : StatusKind.ok,
              description: t.text(
                kernelReleaseChecking
                    ? 'kernels.releaseCheckingDescription'
                    : 'kernels.noNewRelease',
              ),
            )
          else
            for (var index = 0; index < available.length; index++) ...[
              StatusRow(
                label: t.text('kernels.verifiedRelease'),
                value: Text(
                  available[index].version,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                ),
                status: StatusKind.info,
                description: t.text('kernels.publishedRelease', {
                  'date': available[index].releaseDate ?? '-',
                }),
                action: AppButton(
                  label: t.text('common.install'),
                  icon: LucideIcons.download,
                  busy: busyRelease == available[index].version,
                  disabled: unavailable || busyRelease != null,
                  onPressed: () => installKernel(available[index]),
                ),
              ),
              if (index != available.length - 1) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}
