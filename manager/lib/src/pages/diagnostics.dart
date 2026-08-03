import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/core.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  double logHeight = 320;
  double? logWidth;

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: t.text('diagnostics.title'),
          description: t.text('diagnostics.description'),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('diagnostics.diagnosticReport')),
        const SizedBox(height: 16),
        LabeledRow(
          title: t.text('diagnostics.supportReport'),
          description: t.text('diagnostics.reportDescription'),
          trailing: const _ExportLink(),
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('diagnostics.eventLog')),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (logWidth ?? constraints.maxWidth)
                .clamp(320.0, constraints.maxWidth);
            return Align(
              alignment: Alignment.centerLeft,
              child: Stack(
                children: [
                  Container(
                    width: width,
                    height: logHeight,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Neutral.n800.withValues(alpha: 0.70),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: manager.logs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final log = manager.logs[index];
                        return SelectableText(
                          log,
                          style: TextStyle(
                            color: log.contains('Error')
                                ? const Color(0xfff87171)
                                : log.contains('Warning')
                                    ? const Color(0xfffbbf24)
                                    : Neutral.n300,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                          ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          logWidth = (width + details.delta.dx)
                              .clamp(320.0, constraints.maxWidth);
                          logHeight = (logHeight + details.delta.dy)
                              .clamp(192.0, 560.0);
                        });
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpLeftDownRight,
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CustomPaint(painter: _ResizeGripPainter()),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ExportLink extends StatefulWidget {
  const _ExportLink();

  @override
  State<_ExportLink> createState() => _ExportLinkState();
}

class _ExportLinkState extends State<_ExportLink> {
  bool hovered = false;
  bool exporting = false;

  Future<void> export() async {
    final manager = context.manager;
    if (exporting || manager.backendConnection != BackendConnection.native) {
      return;
    }
    setState(() => exporting = true);
    final result = await manager.exportDiagnostics();
    if (result.status == ExportStatus.saved) {
      manager.addLog(
        '[System] Diagnostic report exported to ${result.path}',
      );
    } else if (result.status == ExportStatus.error) {
      manager.addLog(
        '[Error] Diagnostic export failed: ${result.error}',
      );
    }
    if (!mounted) return;
    setState(() => exporting = false);
  }

  @override
  Widget build(BuildContext context) {
    final color = hovered ? context.palette.text : context.palette.textMedium;
    final enabled =
        context.manager.backendConnection == BackendConnection.native;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => hovered = enabled),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? export : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (exporting) ...[
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                context.t.text('common.export'),
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                  decorationColor: context.palette.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              AnimatedSlide(
                offset: hovered ? const Offset(0.12, -0.12) : Offset.zero,
                duration: const Duration(milliseconds: 150),
                child: Icon(LucideIcons.arrowUpRight, size: 14, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Neutral.n500
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width - 4, size.height - 11),
      Offset(size.width - 11, size.height - 4),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - 4, size.height - 7),
      Offset(size.width - 7, size.height - 4),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
