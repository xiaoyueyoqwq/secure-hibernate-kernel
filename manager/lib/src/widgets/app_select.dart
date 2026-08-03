import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';

class AppSelectOption<T> {
  const AppSelectOption(this.value, this.label);

  final T value;
  final String label;
}

class AppSelect<T> extends StatefulWidget {
  const AppSelect({
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = 192,
    this.placementAbove = false,
    this.disabled = false,
    super.key,
  });

  final T value;
  final List<AppSelectOption<T>> options;
  final ValueChanged<T> onChanged;
  final double width;
  final bool placementAbove;
  final bool disabled;

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink link = LayerLink();
  final OverlayPortalController overlay = OverlayPortalController();
  late final AnimationController animation;
  late final Animation<double> fade;
  late final Animation<double> scale;
  late final Animation<Offset> slide;
  bool open = false;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 100),
    );
    fade = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
    scale = Tween(begin: 0.98, end: 1.0).animate(fade);
    slide = Tween(
      begin: Offset(0, widget.placementAbove ? 0.04 : -0.04),
      end: Offset.zero,
    ).animate(fade);
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  Future<void> toggle() async {
    if (widget.disabled) return;
    if (open) {
      await close();
    } else {
      setState(() => open = true);
      overlay.show();
      await animation.forward(from: 0);
    }
  }

  Future<void> close() async {
    if (!open) return;
    setState(() => open = false);
    await animation.reverse();
    if (mounted) overlay.hide();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.options.firstWhere(
      (option) => option.value == widget.value,
    );
    final palette = context.palette;
    return OverlayPortal(
      controller: overlay,
      overlayChildBuilder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: close,
            ),
          ),
          CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: widget.placementAbove
                ? Alignment.topLeft
                : Alignment.bottomLeft,
            followerAnchor: widget.placementAbove
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(0, widget.placementAbove ? -6 : 6),
            child: FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: slide,
                child: ScaleTransition(
                  scale: scale,
                  alignment: widget.placementAbove
                      ? Alignment.bottomCenter
                      : Alignment.topCenter,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: widget.width < 192 ? 192 : widget.width,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: palette.dark ? Neutral.n900 : Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: (palette.dark ? Neutral.n700 : Neutral.n200)
                              .withValues(alpha: palette.dark ? 0.80 : 0.70),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x1a000000),
                            blurRadius: 15,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: widget.options
                            .map(
                              (option) => _SelectMenuItem<T>(
                                option: option,
                                selected: option.value == widget.value,
                                onPressed: () {
                                  widget.onChanged(option.value);
                                  close();
                                },
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      child: CompositedTransformTarget(
        link: link,
        child: Opacity(
          opacity: widget.disabled ? 0.6 : 1,
          child: GestureDetector(
            onTap: toggle,
            child: Container(
              width: widget.width,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.strongBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      selected.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: const Icon(
                      LucideIcons.chevronDown,
                      size: 14,
                      color: Neutral.n400,
                    ),
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

class _SelectMenuItem<T> extends StatefulWidget {
  const _SelectMenuItem({
    required this.option,
    required this.selected,
    required this.onPressed,
  });

  final AppSelectOption<T> option;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_SelectMenuItem<T>> createState() => _SelectMenuItemState<T>();
}

class _SelectMenuItemState<T> extends State<_SelectMenuItem<T>> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          height: 32,
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? palette.dark
                    ? Neutral.n800
                    : Neutral.n100
                : hovered
                    ? palette.dark
                        ? Neutral.n800.withValues(alpha: 0.60)
                        : Neutral.n50
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.option.label,
                  style: TextStyle(
                    color: widget.selected || hovered
                        ? palette.text
                        : palette.textMedium,
                    fontSize: 12,
                    fontWeight:
                        widget.selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.selected)
                Icon(LucideIcons.check, size: 13, color: palette.text),
            ],
          ),
        ),
      ),
    );
  }
}
