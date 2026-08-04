import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_state.dart';
import 'src/pages/kernels.dart';
import 'src/theme.dart';
import 'src/translations.dart';
import 'src/widgets/core.dart';

const _previewReleaseUrl =
    'https://github.com/xiaoyueyoqwq/secure-hibernate-kernel/'
    'releases/tag/manager-v1.0.0+32';

class _PreviewUpdateChecker implements ManagerUpdateChecker {
  const _PreviewUpdateChecker();

  @override
  Future<ManagerUpdateInfo> check(String _) async => const ManagerUpdateInfo(
        state: ManagerUpdateState.available,
        currentVersion: '1.0.0+31',
        latestVersion: '1.0.0+32',
        releaseUrl: _previewReleaseUrl,
      );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(1180, 760),
    minimumSize: Size(760, 560),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: 'Secure Hibernate Update Preview',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  unawaited(windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  }));

  final translations = await TranslationCatalog.load();
  final manager = ManagerController(
    translations,
    updateChecker: const _PreviewUpdateChecker(),
  );
  await manager.checkManagerUpdate();
  runApp(_UpdatePreview(manager: manager));
}

class _UpdatePreview extends StatefulWidget {
  const _UpdatePreview({required this.manager});

  final ManagerController manager;

  @override
  State<_UpdatePreview> createState() => _UpdatePreviewState();
}

class _UpdatePreviewState extends State<_UpdatePreview> {
  @override
  void dispose() {
    widget.manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.manager,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildManagerTheme(Brightness.light),
        darkTheme: buildManagerTheme(Brightness.dark),
        themeMode: widget.manager.themeMode,
        home: ManagerScope(
          controller: widget.manager,
          child: const ManagerShell(
            child: PageViewport(child: KernelsPage()),
          ),
        ),
      ),
    );
  }
}
