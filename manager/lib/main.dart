import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_state.dart';
import 'src/native_backend.dart';
import 'src/pages/diagnostics.dart';
import 'src/pages/installation_wizard.dart';
import 'src/pages/kernels.dart';
import 'src/pages/overview.dart';
import 'src/pages/security.dart';
import 'src/pages/settings.dart';
import 'src/theme.dart';
import 'src/translations.dart';
import 'src/widgets/app_select.dart';
import 'src/widgets/core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(1180, 760),
    minimumSize: Size(760, 560),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: 'Secure Hibernate',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  unawaited(windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  }));

  final translations = await TranslationCatalog.load();
  runApp(
    SecureHibernateManagerApp(
      translations: translations,
      backend: NativeManagerBackend(),
    ),
  );
}

class SecureHibernateManagerApp extends StatefulWidget {
  const SecureHibernateManagerApp({this.translations, this.backend, super.key});

  final TranslationCatalog? translations;
  final ManagerBackend? backend;

  @override
  State<SecureHibernateManagerApp> createState() =>
      _SecureHibernateManagerAppState();
}

class _SecureHibernateManagerAppState extends State<SecureHibernateManagerApp> {
  late final Future<TranslationCatalog> translations =
      widget.translations == null
          ? TranslationCatalog.load()
          : Future.value(widget.translations);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TranslationCatalog>(
      future: translations,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ColoredBox(color: Neutral.n100),
          );
        }
        return _LoadedManager(
          catalog: snapshot.data!,
          backend: widget.backend,
        );
      },
    );
  }
}

class _LoadedManager extends StatefulWidget {
  const _LoadedManager({required this.catalog, this.backend});

  final TranslationCatalog catalog;
  final ManagerBackend? backend;

  @override
  State<_LoadedManager> createState() => _LoadedManagerState();
}

class _LoadedManagerState extends State<_LoadedManager> {
  late final ManagerController manager = ManagerController(
    widget.catalog,
    backend: widget.backend,
  );

  @override
  void dispose() {
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) => MaterialApp(
        title: 'Secure Hibernate',
        debugShowCheckedModeBanner: false,
        themeMode: manager.themeMode,
        theme: buildManagerTheme(Brightness.light),
        darkTheme: buildManagerTheme(Brightness.dark),
        locale: Locale.fromSubtags(
          languageCode: manager.language.code.substring(0, 2),
          countryCode: manager.language.code.substring(3),
        ),
        supportedLocales: const [
          Locale('en', 'US'),
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ManagerScope(
          controller: manager,
          child: !manager.setupProgressLoaded
              ? const _StartupApplication()
              : manager.setupComplete
                  ? const _ManagerApplication()
                  : const _FirstRunApplication(),
        ),
      ),
    );
  }
}

class _StartupApplication extends StatelessWidget {
  const _StartupApplication();

  @override
  Widget build(BuildContext context) {
    return const ManagerShell(
      firstRun: true,
      child: SizedBox.expand(),
    );
  }
}

class _FirstRunApplication extends StatelessWidget {
  const _FirstRunApplication();

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    return ManagerShell(
      firstRun: true,
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (manager.backendConnection == BackendConnection.mock)
                    Text(
                      t.text('alerts.mockData'),
                      style: TextStyle(
                        color: context.palette.dark
                            ? const Color(0xfffbbf24)
                            : const Color(0xffb45309),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (manager.backendConnection == BackendConnection.mock)
                    const SizedBox(width: 12),
                  const SizedBox(width: 12),
                  AppSelect<AppLanguage>(
                    value: manager.language,
                    width: 160,
                    options: [
                      AppSelectOption(
                        AppLanguage.enUS,
                        t.text('language.enUS'),
                      ),
                      AppSelectOption(
                        AppLanguage.zhCN,
                        t.text('language.zhCN'),
                      ),
                      AppSelectOption(
                        AppLanguage.zhTW,
                        t.text('language.zhTW'),
                      ),
                    ],
                    onChanged: manager.setLanguage,
                  ),
                ],
              ),
            ),
          ),
          const Expanded(
            child: PageViewport(child: InstallationWizardPage()),
          ),
        ],
      ),
    );
  }
}

class _ManagerApplication extends StatelessWidget {
  const _ManagerApplication();

  @override
  Widget build(BuildContext context) {
    final page = switch (context.manager.activePage) {
      ManagerPage.overview => const OverviewPage(),
      ManagerPage.wizard => const InstallationWizardPage(),
      ManagerPage.kernels => const KernelsPage(),
      ManagerPage.security => const SecurityPage(),
      ManagerPage.settings => const SettingsPage(),
      ManagerPage.diagnostics => const DiagnosticsPage(),
    };
    return ManagerShell(
      child: PageViewport(
        key: ValueKey(context.manager.activePage),
        child: page,
      ),
    );
  }
}
