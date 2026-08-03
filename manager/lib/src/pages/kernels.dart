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
    if (!manager.native) {
      manager.addLog('Requested uninstall on kernel ${kernel.version}');
      return;
    }
    if (pendingRemoval != kernel.version) {
      setState(() => pendingRemoval = kernel.version);
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
    final installed = manager.kernels
        .where((kernel) => kernel.status == KernelStatus.installed)
        .toList();
    final available = manager.kernels
        .where((kernel) => kernel.status == KernelStatus.available)
        .toList();
    final unavailable =
        manager.backendConnection == BackendConnection.loading ||
            manager.backendConnection == BackendConnection.error;
    return Column(
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
        const SizedBox(height: 32),
        SectionTitle(t.text('kernels.installedFallbacks')),
        const SizedBox(height: 16),
        for (var index = 0; index < installed.length; index++) ...[
          StatusRow(
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
                    label: '',
                    width: 32,
                    height: 32,
                    icon: LucideIcons.trash2,
                    tone: pendingRemoval == installed[index].version
                        ? ButtonTone.danger
                        : ButtonTone.ghost,
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
        if (available.isEmpty)
          StatusRow(
            label: t.text('kernels.releaseStatus'),
            value: Text(t.text('kernels.upToDate')),
            status: StatusKind.ok,
            description: t.text('kernels.noNewRelease'),
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
    );
  }
}
