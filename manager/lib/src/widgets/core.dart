import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../theme.dart';

const appIconAsset = 'linux/resources/app-icon.png';

bool usesLegacyMokPassword(String? password) =>
    password != null && RegExp(r'^[A-Za-z0-9]{12}$').hasMatch(password);

Future<Uint8List?> showLuksRecoveryPasswordDialog(
  BuildContext context,
) async {
  final t = context.t;
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LuksRecoveryPasswordDialog(
      title: t.text('wizard.luksPasswordTitle'),
      description: t.text('wizard.luksPasswordDescription'),
      fieldLabel: t.text('wizard.luksPasswordField'),
      requiredError: t.text('wizard.luksPasswordRequired'),
      cancelLabel: t.text('common.cancel'),
      continueLabel: t.text('common.continue'),
    ),
  );
}

class _LuksRecoveryPasswordDialog extends StatefulWidget {
  const _LuksRecoveryPasswordDialog({
    required this.title,
    required this.description,
    required this.fieldLabel,
    required this.requiredError,
    required this.cancelLabel,
    required this.continueLabel,
  });

  final String title;
  final String description;
  final String fieldLabel;
  final String requiredError;
  final String cancelLabel;
  final String continueLabel;

  @override
  State<_LuksRecoveryPasswordDialog> createState() =>
      _LuksRecoveryPasswordDialogState();
}

class _LuksRecoveryPasswordDialogState
    extends State<_LuksRecoveryPasswordDialog> {
  final controller = TextEditingController();
  final focusNode = FocusNode();
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    controller.clear();
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  void submit() {
    final value = controller.text;
    if (value.isEmpty) {
      setState(() => error = widget.requiredError);
      return;
    }
    final password = Uint8List.fromList(utf8.encode(value));
    controller.clear();
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Material(
          key: const ValueKey('luks-password-dialog'),
          color: context.palette.card,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: context.palette.strongBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.lockKeyhole,
                          size: 18, color: context.palette.text),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: TextStyle(
                            color: context.palette.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.description,
                    style: TextStyle(
                      color: context.palette.textMedium,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('luks-password-field'),
                    controller: controller,
                    focusNode: focusNode,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => submit(),
                    onChanged: (_) {
                      if (error != null) setState(() => error = null);
                    },
                    decoration: InputDecoration(
                      labelText: widget.fieldLabel,
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AppButton(
                        label: widget.cancelLabel,
                        tone: ButtonTone.ghost,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 8),
                      AppButton(
                        label: widget.continueLabel,
                        icon: LucideIcons.arrowRight,
                        onPressed: submit,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      height: 36,
      child: ColoredBox(
        color: palette.outerBackground,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () async {
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
                child: DragToMoveArea(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    child: Row(
                      children: [
                        Image.asset(
                          appIconAsset,
                          width: 16,
                          height: 16,
                          filterQuality: FilterQuality.high,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Secure Hibernate',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.dark ? Neutral.n200 : Neutral.n700,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            WindowControl(
              icon: LucideIcons.minus,
              tooltip: context.t.text('common.minimizeWindow'),
              onPressed: windowManager.minimize,
            ),
            WindowControl(
              icon: LucideIcons.square,
              iconSize: 11,
              tooltip: context.t.text('common.toggleMaximizeWindow'),
              onPressed: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            WindowControl(
              icon: LucideIcons.x,
              iconSize: 15,
              close: true,
              tooltip: context.t.text('common.closeWindow'),
              onPressed: windowManager.close,
            ),
          ],
        ),
      ),
    );
  }
}

class WindowControl extends StatefulWidget {
  const WindowControl({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 14,
    this.close = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function() onPressed;
  final double iconSize;
  final bool close;

  @override
  State<WindowControl> createState() => _WindowControlState();
}

class _WindowControlState extends State<WindowControl> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            width: 44,
            height: 36,
            duration: const Duration(milliseconds: 120),
            color: hovered
                ? widget.close
                    ? const Color(0xffdc2626)
                    : palette.dark
                        ? Neutral.n800
                        : Neutral.n200.withValues(alpha: 0.70)
                : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: hovered && widget.close
                  ? Colors.white
                  : hovered
                      ? palette.text
                      : palette.dark
                          ? Neutral.n400
                          : Neutral.n500,
            ),
          ),
        ),
      ),
    );
  }
}

class ManagerShell extends StatelessWidget {
  const ManagerShell({required this.child, this.firstRun = false, super.key});

  final Widget child;
  final bool firstRun;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      backgroundColor: palette.outerBackground,
      body: Stack(
        children: [
          Column(
            children: [
              const WindowTitleBar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                  child: firstRun
                      ? _MainSurface(child: child)
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const AppSidebar(),
                            const SizedBox(width: 6),
                            Expanded(child: _MainSurface(child: child)),
                          ],
                        ),
                ),
              ),
            ],
          ),
          const ManagerNoticeOverlay(),
        ],
      ),
    );
  }
}

class ManagerNoticeOverlay extends StatelessWidget {
  const ManagerNoticeOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final width =
        (MediaQuery.sizeOf(context).width - 24).clamp(240.0, 368.0).toDouble();
    return Positioned(
      top: 44,
      right: 12,
      child: SafeArea(
        child: SizedBox(
          width: width,
          child: IgnorePointer(
            ignoring: manager.notices.isEmpty,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, -0.05),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: manager.notices.isEmpty
                  ? const SizedBox.shrink(key: ValueKey('empty-notices'))
                  : Column(
                      key: ValueKey(
                        manager.notices.map((notice) => notice.id).join(','),
                      ),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final notice in manager.notices) ...[
                          ManagerNoticeCard(notice: notice),
                          if (notice != manager.notices.last)
                            const SizedBox(height: 8),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class ManagerNoticeCard extends StatelessWidget {
  const ManagerNoticeCard({required this.notice, super.key});

  final ManagerNotice notice;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (icon, accent) = switch (notice.type) {
      ManagerNoticeType.info => (LucideIcons.info, const Color(0xff2563eb)),
      ManagerNoticeType.success => (
          LucideIcons.checkCircle2,
          const Color(0xff059669)
        ),
      ManagerNoticeType.warning => (
          LucideIcons.circleAlert,
          const Color(0xffd97706)
        ),
      ManagerNoticeType.error => (LucideIcons.circleX, const Color(0xffdc2626)),
      ManagerNoticeType.loading => (LucideIcons.loader2, palette.textMedium),
    };
    final iconWidget = notice.type == ManagerNoticeType.loading
        ? SizedBox.square(
            dimension: 17,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: accent,
            ),
          )
        : Icon(icon, size: 17, color: accent);
    return Material(
      color: palette.card,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: palette.dark ? 0.35 : 0.12),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: iconWidget),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notice.title,
                    style: TextStyle(
                      color: palette.textStrong,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (notice.description != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      notice.description!,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textMedium,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: context.t.text('common.close'),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.manager.dismissNotice(notice.id),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    LucideIcons.x,
                    size: 14,
                    color: palette.textMuted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MainSurface extends StatelessWidget {
  const _MainSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey('manager-main-surface'),
      decoration: BoxDecoration(
        color: context.palette.contentBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: context.palette.dark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0d000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    );
  }
}

class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final items = <({ManagerPage page, String label, IconData icon})>[
      (
        page: ManagerPage.overview,
        label: context.t.text('nav.overview'),
        icon: LucideIcons.gauge,
      ),
      (
        page: ManagerPage.wizard,
        label: context.t.text('nav.wizard'),
        icon: LucideIcons.packagePlus,
      ),
      (
        page: ManagerPage.kernels,
        label: context.t.text('nav.kernels'),
        icon: LucideIcons.boxes,
      ),
      (
        page: ManagerPage.security,
        label: context.t.text('nav.security'),
        icon: LucideIcons.shieldEllipsis,
      ),
      (
        page: ManagerPage.settings,
        label: context.t.text('nav.preferences'),
        icon: LucideIcons.slidersHorizontal,
      ),
      if (manager.advancedMode)
        (
          page: ManagerPage.diagnostics,
          label: context.t.text('nav.diagnostics'),
          icon: LucideIcons.fileTerminal,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final expanded = MediaQuery.sizeOf(context).width >= 768;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: expanded ? 224 : 56,
          color: Colors.transparent,
          child: Column(
            children: [
              SizedBox(
                height: 56,
                child: expanded
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              SimpleIcons.linux,
                              size: 16,
                              color: context.palette.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Secure Hibernate',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.palette.textStrong,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    expanded ? 12 : 6,
                    8,
                    expanded ? 12 : 6,
                    8,
                  ),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return SidebarItem(
                      label: item.label,
                      icon: item.icon,
                      selected: manager.activePage == item.page,
                      expanded: expanded,
                      onPressed: () => manager.setPage(item.page),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SidebarItem extends StatefulWidget {
  const SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.expanded,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  State<SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<SidebarItem> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final content = MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          height: 32,
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(horizontal: widget.expanded ? 8 : 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? palette.dark
                    ? Neutral.n800
                    : Neutral.n200.withValues(alpha: 0.70)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: widget.expanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: widget.selected
                    ? palette.text
                    : hovered
                        ? palette.dark
                            ? Neutral.n200
                            : Neutral.n900
                        : Neutral.n500,
              ),
              if (widget.expanded) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.selected
                          ? palette.text
                          : hovered
                              ? palette.dark
                                  ? Neutral.n200
                                  : Neutral.n900
                              : Neutral.n500,
                      fontSize: 12,
                      fontWeight:
                          widget.selected ? FontWeight.w500 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return content;
  }
}

class PageViewport extends StatelessWidget {
  const PageViewport({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth >= 1280
            ? 32.0
            : constraints.maxWidth >= 640
                ? 24.0
                : 16.0;
        final contentWidth =
            (constraints.maxWidth - padding * 2).clamp(0.0, 896.0).toDouble();
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            primary: true,
            padding: EdgeInsets.all(padding),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: contentWidth, child: child),
            ),
          ),
        );
      },
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({required this.title, this.description, super.key});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(description!, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.titleSmall);
}

class AppCard extends StatelessWidget {
  const AppCard({required this.child, this.padding, this.color, super.key});

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? context.palette.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.palette.border),
      ),
      child: child,
    );
  }
}

enum StatusKind { ok, error, warning, info, pending, loading }

class StatusGlyph extends StatelessWidget {
  const StatusGlyph(
    this.status, {
    this.size = 18,
    this.icon,
    this.color,
    super.key,
  });

  final StatusKind status;
  final double size;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      StatusKind.ok => (LucideIcons.checkCircle2, const Color(0xff059669)),
      StatusKind.error => (LucideIcons.circleX, const Color(0xffdc2626)),
      StatusKind.warning => (LucideIcons.circleAlert, const Color(0xfff59e0b)),
      StatusKind.info => (LucideIcons.info, const Color(0xff3b82f6)),
      StatusKind.pending => (LucideIcons.clock3, context.palette.textMuted),
      StatusKind.loading => (LucideIcons.loader2, context.palette.textMedium),
    };
    final glyph =
        Icon(this.icon ?? icon, size: size, color: this.color ?? color);
    return status == StatusKind.loading
        ? SizedBox.square(
            dimension: size,
            child: const CircularProgressIndicator(strokeWidth: 1.5),
          )
        : glyph;
  }
}

class StatusRow extends StatelessWidget {
  const StatusRow({
    required this.label,
    required this.value,
    required this.status,
    this.description,
    this.action,
    this.statusIcon,
    this.statusColor,
    super.key,
  });

  final String label;
  final Widget value;
  final StatusKind status;
  final String? description;
  final Widget? action;
  final IconData? statusIcon;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 520;
          final details = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: StatusGlyph(
                  status,
                  icon: statusIcon,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '$label:',
                          style: TextStyle(
                            color: context.palette.textStrong,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        DefaultTextStyle(
                          style: TextStyle(
                            color: context.palette.textMedium,
                            fontFamily: 'Ubuntu',
                            fontSize: 14,
                          ),
                          child: value,
                        ),
                      ],
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        description!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
          if (action == null) return details;
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [details, const SizedBox(height: 12), action!],
            );
          }
          return Row(
            children: [
              Expanded(child: details),
              const SizedBox(width: 16),
              action!,
            ],
          );
        },
      ),
    );
  }
}

enum ButtonTone { primary, neutral, danger, ghost }

class AppButton extends StatefulWidget {
  const AppButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.width,
    this.height = 36,
    this.tone = ButtonTone.primary,
    this.disabled = false,
    this.busy = false,
    this.selected = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final double? width;
  final double height;
  final ButtonTone tone;
  final bool disabled;
  final bool busy;
  final bool selected;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final disabled = widget.disabled || widget.busy;
    final ghostBackground = palette.dark ? Neutral.n800 : Neutral.n100;
    final (background, foreground, border) = switch (widget.tone) {
      ButtonTone.primary => (
          hovered
              ? (palette.dark ? Neutral.n200 : Neutral.n800)
              : palette.activeFill,
          palette.activeText,
          Colors.transparent,
        ),
      ButtonTone.neutral => (
          palette.card,
          palette.text,
          hovered ? Neutral.n400 : palette.strongBorder,
        ),
      ButtonTone.danger => (
          hovered ? const Color(0xff991b1b) : const Color(0xffb91c1c),
          Colors.white,
          const Color(0xffb91c1c),
        ),
      ButtonTone.ghost => (
          hovered || widget.selected
              ? ghostBackground
              : ghostBackground.withValues(alpha: 0),
          palette.textMedium,
          Colors.transparent,
        ),
    };
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: disabled ? null : widget.onPressed,
          child: AnimatedContainer(
            width: widget.width ?? _contentWidth(context),
            height: widget.height,
            padding: EdgeInsets.symmetric(
              horizontal: widget.label.isEmpty ? 8 : 12,
            ),
            duration: const Duration(milliseconds: 130),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: border),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.busy)
                  SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: foreground,
                    ),
                  )
                else if (widget.icon != null)
                  Icon(widget.icon, size: 14, color: foreground),
                if (widget.label.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: widget.busy || widget.icon != null ? 8 : 0,
                      ),
                      child: Text(
                        widget.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _contentWidth(BuildContext context) {
    final text = TextPainter(
      text: TextSpan(
        text: widget.label,
        style: const TextStyle(
          fontFamily: 'Ubuntu',
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final leadingWidth = widget.busy
        ? 15.0
        : widget.icon == null
            ? 0.0
            : 14.0;
    final spacing = leadingWidth > 0 && widget.label.isNotEmpty ? 8.0 : 0.0;
    final padding = widget.label.isEmpty ? 16.0 : 24.0;
    return (padding + leadingWidth + spacing + text.width).ceilToDouble();
  }
}

class AppSwitch extends StatelessWidget {
  const AppSwitch({required this.value, this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = context.palette.dark;
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: Opacity(
        opacity: onChanged == null ? 0.45 : 1,
        child: GestureDetector(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: AnimatedContainer(
            width: 44,
            height: 24,
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value
                  ? dark
                      ? Colors.white
                      : Colors.black
                  : dark
                      ? Neutral.n700
                      : Neutral.n200,
              borderRadius: BorderRadius.circular(999),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: value && dark ? Colors.black : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: value
                        ? value && dark
                            ? Colors.black
                            : Colors.white
                        : Neutral.n300,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CopyableCode extends StatefulWidget {
  const CopyableCode(this.value, {super.key});

  final String value;

  @override
  State<CopyableCode> createState() => _CopyableCodeState();
}

class _CopyableCodeState extends State<CopyableCode> {
  bool copied = false;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    setState(() => copied = true);
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      constraints: const BoxConstraints(maxWidth: double.infinity),
      decoration: BoxDecoration(
        color: palette.dark ? Neutral.n900 : Neutral.n100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: (palette.dark ? Neutral.n700 : Neutral.n200)
              .withValues(alpha: 0.70),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
              child: SelectableText(
                widget.value,
                style: TextStyle(
                  color: palette.dark ? Neutral.n200 : Neutral.n800,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
          Tooltip(
            message: copied
                ? context.t.text('common.copied')
                : context.t.text('common.copy'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: copy,
              child: SizedBox(
                width: 28,
                height: 28,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    copied ? LucideIcons.check : LucideIcons.copy,
                    key: ValueKey(copied),
                    size: 13,
                    color: copied ? const Color(0xff059669) : Neutral.n400,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LabeledRow extends StatelessWidget {
  const LabeledRow({
    required this.title,
    this.description,
    required this.trailing,
    super.key,
  });

  final String title;
  final String? description;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: context.palette.textStrong,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(description!,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 16), trailing],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 20),
              trailing,
            ],
          );
        },
      ),
    );
  }
}
