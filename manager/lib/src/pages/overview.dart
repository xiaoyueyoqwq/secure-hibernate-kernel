import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/core.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    final operational = manager.secureBoot &&
        manager.lockdown &&
        manager.hibernationCapacity &&
        manager.grubConfigured &&
        manager.projectMokStatus == ProjectMokStatus.enrolled &&
        manager.activeKernel.project &&
        manager.officialFallbackInstalled;
    final enhancementRecommended = operational && !manager.luks;
    final ready = operational && manager.luks;
    final policy = switch (manager.updatePolicy) {
      UpdatePolicy.automaticInstall => t.text('overview.automaticInstall'),
      UpdatePolicy.checkAndNotify => t.text('overview.checkAndNotify'),
      UpdatePolicy.manual => t.text('wizard.details.manualPolicy'),
    };
    final updateAvailable = manager.kernels
        .any((kernel) => kernel.status == KernelStatus.available);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: t.text('overview.title')),
        const SizedBox(height: 32),
        AppCard(
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final state = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          ready
                              ? LucideIcons.checkCircle2
                              : LucideIcons.alertCircle,
                          size: 21,
                          color: ready
                              ? const Color(0xff059669)
                              : const Color(0xfff59e0b),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          ready
                              ? t.text('overview.ready')
                              : enhancementRecommended
                                  ? t.text(
                                      'overview.securityEnhancementRecommended')
                                  : t.text('overview.needsAttention'),
                          style: TextStyle(
                            color: context.palette.text,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    );
                    final summary = Text(
                      ready
                          ? t.text('overview.allChecksPassed')
                          : enhancementRecommended
                              ? t.text('overview.unencryptedHibernationWarning')
                              : t.text('overview.reviewChecks'),
                      style: TextStyle(
                        color: context.palette.textMedium,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                    if (constraints.maxWidth < 540) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [state, const SizedBox(height: 16), summary],
                      );
                    }
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [state, summary],
                    );
                  },
                ),
              ),
              Container(height: 1, color: context.palette.border),
              LayoutBuilder(
                builder: (context, constraints) {
                  final details = [
                    _SystemDetail(
                      label: t.text('overview.device'),
                      child: Text(manager.deviceName.isEmpty
                          ? t.text('overview.unknown')
                          : manager.deviceName),
                    ),
                    _SystemDetail(
                      label: t.text('overview.runningKernel'),
                      child: CopyableCode(manager.activeKernel.version.isEmpty
                          ? t.text('overview.unknown')
                          : manager.activeKernel.version),
                    ),
                    _SystemDetail(
                      label: t.text('overview.operatingSystem'),
                      child: Text(manager.ubuntuVersion.isEmpty
                          ? t.text('overview.unknown')
                          : manager.ubuntuVersion),
                    ),
                    _SystemDetail(
                      label: t.text('overview.updatePolicy'),
                      child: Text(policy),
                    ),
                  ];
                  if (constraints.maxWidth < 640) {
                    return Column(
                      children: [
                        for (var index = 0;
                            index < details.length;
                            index++) ...[
                          details[index],
                          if (index != details.length - 1)
                            Container(height: 1, color: context.palette.border),
                        ],
                      ],
                    );
                  }
                  return Table(
                    border: TableBorder(
                      horizontalInside:
                          BorderSide(color: context.palette.border),
                      verticalInside: BorderSide(color: context.palette.border),
                    ),
                    children: [
                      TableRow(children: [details[0], details[1]]),
                      TableRow(children: [details[2], details[3]]),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('overview.manage')),
        const SizedBox(height: 16),
        _ActionCard(
          title: t.text('nav.kernels'),
          description: t.text('overview.kernelsDescription'),
          status: updateAvailable
              ? t.text('overview.review')
              : t.text('overview.upToDate'),
          openLabel: t.text('common.open'),
          onPressed: () => manager.setPage(ManagerPage.kernels),
        ),
        const SizedBox(height: 12),
        _ActionCard(
          key: const ValueKey('overview-manager-updates'),
          title: t.text('overview.managerUpdates'),
          description: t.text('overview.managerUpdatesDescription'),
          status: t.text('overview.independentChannel'),
          openLabel: t.text('common.open'),
          onPressed: () => manager.setPage(ManagerPage.kernels),
        ),
        const SizedBox(height: 12),
        _ActionCard(
          title: t.text('nav.security'),
          description: t.text('overview.securityDescription'),
          status: !manager.luks
              ? t.text('overview.securityEnhancementRecommended')
              : manager.projectMokStatus == ProjectMokStatus.enrolled
                  ? t.text('overview.protected')
                  : t.text('overview.review'),
          openLabel: t.text('common.open'),
          onPressed: () => manager.setPage(ManagerPage.security),
        ),
        const SizedBox(height: 12),
        _ActionCard(
          title: t.text('nav.preferences'),
          description: t.text('overview.preferencesDescription'),
          status: manager.officialFallbackInstalled
              ? t.text('overview.fallbackRetained')
              : t.text('overview.reviewFallback'),
          openLabel: t.text('common.open'),
          onPressed: () => manager.setPage(ManagerPage.settings),
        ),
      ],
    );
  }
}

class _SystemDetail extends StatelessWidget {
  const _SystemDetail({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Neutral.n500, fontSize: 12),
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: TextStyle(
              color: context.palette.textStrong,
              fontFamily: 'Ubuntu',
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatefulWidget {
  const _ActionCard({
    required this.title,
    required this.description,
    required this.status,
    required this.openLabel,
    required this.onPressed,
    super.key,
  });

  final String title;
  final String description;
  final String status;
  final String openLabel;
  final VoidCallback onPressed;

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: context.palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: hovered
                  ? context.palette.dark
                      ? Neutral.n700.withValues(alpha: 0.80)
                      : Neutral.n300.withValues(alpha: 0.80)
                  : context.palette.border,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final left = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: context.palette.textStrong,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(widget.description,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              );
              final right = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.status,
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    widget.openLabel,
                    style: TextStyle(
                      color: context.palette.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [left, const SizedBox(height: 12), right],
                );
              }
              return Row(
                children: [
                  Expanded(child: left),
                  const SizedBox(width: 16),
                  right,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
