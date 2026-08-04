import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:secure_hibernate_manager/src/app_state.dart';
import 'package:secure_hibernate_manager/src/backend.dart';
import 'package:secure_hibernate_manager/main.dart';
import 'package:secure_hibernate_manager/src/pages/installation_wizard.dart';
import 'package:secure_hibernate_manager/src/translations.dart';
import 'package:secure_hibernate_manager/src/theme.dart';
import 'package:secure_hibernate_manager/src/widgets/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

TranslationCatalog? _translations;

UpdateControllerStatus testUpdaterStatus({
  String? status,
  String? checkedAt,
  bool checkServiceActive = false,
  int? downloadedBytes,
  int? totalBytes,
  String? checkFailedPhase,
  String? lastCheckError,
}) =>
    UpdateControllerStatus(
      controllerInstalled: true,
      policy: UpdatePolicy.checkAndNotify,
      lastCheckStatus: status,
      lastCheckedAt: checkedAt,
      availableSourceVersion: null,
      availableKernelRelease: null,
      installedSourceVersion: null,
      installedKernelRelease: null,
      rebootRequired: false,
      timerEnabled: true,
      timerActive: true,
      nextCheckAt: null,
      checkServiceActive: checkServiceActive,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      currentAsset: null,
      checkFailedPhase: checkFailedPhase,
      lastCheckError: lastCheckError,
    );

SystemSnapshot testSnapshot(
  UpdateControllerStatus updater, {
  bool luks = true,
  bool hibernatePartition = true,
}) =>
    SystemSnapshot(
      collectedAt: DateTime.utc(2026),
      systemStatus: SystemStatus(
        deviceName: 'test',
        ubuntuVersion: 'Ubuntu',
        secureBoot: true,
        lockdown: true,
        luks: luks,
        tpmConfigured: luks,
        hibernatePartition: hibernatePartition,
        grubUpdated: true,
        projectHeadersInstalled: true,
      ),
      kernels: const [
        KernelInfo(
          id: 'official',
          version: '7.0.0-28-generic',
          project: false,
          status: KernelStatus.active,
        ),
      ],
      preflightDiagnostics: const [],
      updater: updater,
      warnings: const [],
    );

class _CancelledManagerBackend implements ManagerBackend {
  const _CancelledManagerBackend({
    this.luks = true,
    this.hibernatePartition = true,
  });

  final bool luks;
  final bool hibernatePartition;

  @override
  Future<SystemSnapshot> getSnapshot() async => testSnapshot(
        const UpdateControllerStatus.empty(),
        luks: luks,
        hibernatePartition: hibernatePartition,
      );

  @override
  Future<InstallProgress> getInstallProgress() async =>
      const InstallProgress.idle();

  @override
  Future<ProjectMokInspection> inspectProjectMok() async =>
      const ProjectMokInspection(
        status: ProjectMokStatus.cancelled,
        fingerprintSha256: null,
        error: null,
        oneTimePassword: null,
      );

  @override
  Future<ManagerActionResult> runManagerAction(
    ManagerActionRequest request,
  ) async =>
      ManagerActionResult(
        action: request.action,
        status: ManagerActionStatus.cancelled,
        error: null,
        data: const ManagerActionData(),
      );

  @override
  Future<SetupProgress> getSetupProgress() async =>
      const SetupProgress(checkpoint: null, completed: false);

  @override
  Future<SetupProgress> clearSetupCheckpoint() async =>
      const SetupProgress(checkpoint: null, completed: false);

  @override
  Future<SetupProgress> completeSetup(bool requireTpm) async =>
      const SetupProgress(checkpoint: null, completed: true);

  @override
  Future<SetupProgress> saveSetupCheckpoint(SetupCheckpoint checkpoint) async =>
      SetupProgress(checkpoint: checkpoint, completed: false);

  @override
  Future<SystemActionResult> restartForSetup(
          SetupCheckpoint checkpoint) async =>
      const SystemActionResult(
          status: SystemActionStatus.cancelled, error: null);

  @override
  Future<ExportResult> exportDiagnostics() async =>
      const ExportResult(status: ExportStatus.cancelled, path: null);
}

class _DelayedCompletedBackend extends _CancelledManagerBackend {
  final Completer<SetupProgress> progress = Completer<SetupProgress>();

  @override
  Future<SetupProgress> getSetupProgress() => progress.future;
}

class _StartCheckRaceBackend extends _CancelledManagerBackend {
  bool started = false;
  int readsAfterStart = 0;

  @override
  Future<SystemSnapshot> getSnapshot() async {
    if (!started) {
      return testSnapshot(testUpdaterStatus(
        status: 'release-unavailable',
        checkedAt: '2026-08-02T12:00:00Z',
      ));
    }
    readsAfterStart += 1;
    if (readsAfterStart == 1) {
      return testSnapshot(testUpdaterStatus(
        status: 'release-unavailable',
        checkedAt: '2026-08-02T12:00:00Z',
      ));
    }
    return testSnapshot(testUpdaterStatus(
      status: 'downloading',
      checkedAt: '2026-08-02T12:00:01Z',
      checkServiceActive: true,
      downloadedBytes: 10,
      totalBytes: 100,
    ));
  }

  @override
  Future<ManagerActionResult> runManagerAction(
    ManagerActionRequest request,
  ) async {
    started = true;
    return ManagerActionResult(
      action: request.action,
      status: ManagerActionStatus.success,
      error: null,
      data: const ManagerActionData(),
    );
  }
}

class _FixedUpdaterBackend extends _CancelledManagerBackend {
  const _FixedUpdaterBackend(this.updater);

  final UpdateControllerStatus updater;

  @override
  Future<SystemSnapshot> getSnapshot() async => testSnapshot(updater);
}

class _MokResumeWithStaleDownloadBackend extends _CancelledManagerBackend {
  int snapshotReads = 0;
  int mokInspections = 0;

  @override
  Future<SetupProgress> getSetupProgress() async => const SetupProgress(
        checkpoint: SetupCheckpoint.awaitingMokEnrollment,
        completed: false,
      );

  @override
  Future<SystemSnapshot> getSnapshot() async {
    snapshotReads += 1;
    return testSnapshot(testUpdaterStatus(
      status: 'downloading',
      checkedAt: '2026-08-03T00:00:00Z',
      checkServiceActive: false,
      downloadedBytes: 14,
      totalBytes: 100,
    ));
  }

  @override
  Future<ProjectMokInspection> inspectProjectMok() async {
    mokInspections += 1;
    return const ProjectMokInspection(
      status: ProjectMokStatus.missing,
      fingerprintSha256:
          '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
          'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11',
      error: null,
      oneTimePassword: null,
    );
  }
}

class _StartupMokBackend extends _CancelledManagerBackend {
  int mokInspections = 0;

  @override
  Future<SetupProgress> getSetupProgress() async =>
      const SetupProgress(checkpoint: null, completed: true);

  @override
  Future<ProjectMokInspection> inspectProjectMok() async {
    mokInspections += 1;
    return const ProjectMokInspection(
      status: ProjectMokStatus.enrolled,
      fingerprintSha256:
          '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
          'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11',
      error: null,
      oneTimePassword: null,
    );
  }
}

class _LegacyMokPasswordBackend extends _CancelledManagerBackend {
  int prepareRequests = 0;

  @override
  Future<SetupProgress> getSetupProgress() async => const SetupProgress(
        checkpoint: SetupCheckpoint.awaitingMokEnrollment,
        completed: false,
      );

  @override
  Future<ProjectMokInspection> inspectProjectMok() async =>
      const ProjectMokInspection(
        status: ProjectMokStatus.pendingEnrollment,
        fingerprintSha256:
            '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
            'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11',
        error: null,
        oneTimePassword: 'Sensitive123',
      );

  @override
  Future<ManagerActionResult> runManagerAction(
    ManagerActionRequest request,
  ) async {
    if (request.action != ManagerActionType.prepareMok) {
      return super.runManagerAction(request);
    }
    prepareRequests += 1;
    return const ManagerActionResult(
      action: ManagerActionType.prepareMok,
      status: ManagerActionStatus.success,
      error: null,
      data: ManagerActionData(
        mokStatus: 'pending',
        fingerprintSha256:
            '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
            'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11',
        oneTimePassword: 'abc23456',
      ),
    );
  }
}

class _RecordingTpmBackend extends _CancelledManagerBackend {
  _RecordingTpmBackend({this.configured = true, this.cancelled = false});

  final bool configured;
  final bool cancelled;
  final List<ManagerActionRequest> requests = [];

  @override
  Future<ProjectMokInspection> inspectProjectMok() async =>
      const ProjectMokInspection(
        status: ProjectMokStatus.enrolled,
        fingerprintSha256:
            '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
            'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11',
        error: null,
        oneTimePassword: null,
      );

  @override
  Future<ManagerActionResult> runManagerAction(
    ManagerActionRequest request,
  ) async {
    requests.add(request);
    if (cancelled) {
      return ManagerActionResult(
        action: request.action,
        status: ManagerActionStatus.cancelled,
        error: null,
        data: const ManagerActionData(),
      );
    }
    return ManagerActionResult(
      action: request.action,
      status: ManagerActionStatus.success,
      error: null,
      data: ManagerActionData(
        alreadyConfigured: configured,
        tokens: configured
            ? const [ManagerTokenResult(tokenId: '0', passed: true)]
            : const [],
      ),
    );
  }
}

Future<void> pumpManager(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  final translations = _translations ?? await TranslationCatalog.load();
  _translations = translations;
  await tester.pumpWidget(
    SecureHibernateManagerApp(translations: translations),
  );
  await tester.pumpAndSettle();
}

Future<void> completeMockSetup(WidgetTester tester) async {
  await tester.tap(find.text('TPM'));
  await tester.pump(const Duration(milliseconds: 800));
  await tester.tap(find.text('Check TPM'));
  await tester.pump(const Duration(milliseconds: 1300));
  await tester.pump();
  await tester.tap(find.text('Finish'));
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('LUKS password dialog captures and dismisses the real route',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final manager = ManagerController(translations);
    Uint8List? submitted;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildManagerTheme(Brightness.light),
        home: ManagerScope(
          controller: manager,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                submitted = await showLuksRecoveryPasswordDialog(context);
              },
              child: const Text('Open password dialog'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open password dialog'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('luks-password-dialog')), findsOneWidget);
    expect(find.text('Enter the LUKS recovery password'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);

    await tester.tap(find.text('Open password dialog'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('luks-password-field')),
      'disk-secret',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(submitted, utf8.encode('disk-secret'));
    submitted?.fillRange(0, submitted!.length, 0);
    manager.dispose();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('TPM check is explicit and does not request a LUKS password',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _RecordingTpmBackend();

    await tester.pumpWidget(
      SecureHibernateManagerApp(translations: translations, backend: backend),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('TPM'));
    await tester.pumpAndSettle();

    expect(find.text('Check TPM'), findsOneWidget);
    expect(backend.requests, isEmpty);
    expect(find.byKey(const ValueKey('luks-password-dialog')), findsNothing);

    await tester.tap(find.text('Check TPM'));
    await tester.pumpAndSettle();

    expect(backend.requests, hasLength(1));
    expect(backend.requests.single.action, ManagerActionType.verifyTpm);
    expect(backend.requests.single.recoveryPassword, isNull);
    expect(find.byKey(const ValueKey('luks-password-dialog')), findsNothing);
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Verify Recovery'), findsOneWidget);
  });

  testWidgets('missing TPM token requires a separate configuration click',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _RecordingTpmBackend(configured: false);

    await tester.pumpWidget(
      SecureHibernateManagerApp(translations: translations, backend: backend),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('TPM'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check TPM'));
    await tester.pumpAndSettle();

    expect(backend.requests.single.action, ManagerActionType.verifyTpm);
    expect(find.text('Needs configuration'), findsOneWidget);
    expect(find.text('Configure TPM'), findsOneWidget);
    expect(find.byKey(const ValueKey('luks-password-dialog')), findsNothing);

    await tester.tap(find.text('Configure TPM'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('luks-password-dialog')), findsOneWidget);
    expect(backend.requests, hasLength(1));
  });

  testWidgets('cancelled TPM inspection remains retryable', (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _RecordingTpmBackend(cancelled: true);

    await tester.pumpWidget(
      SecureHibernateManagerApp(translations: translations, backend: backend),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('TPM'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check TPM'));
    await tester.pumpAndSettle();

    expect(backend.requests.single.action, ManagerActionType.verifyTpm);
    expect(backend.requests.single.recoveryPassword, isNull);
    expect(find.text('Check TPM'), findsOneWidget);
    expect(find.text('Configure TPM'), findsNothing);
    expect(find.byKey(const ValueKey('luks-password-dialog')), findsNothing);
  });

  testWidgets('first run shows the seven-step installation wizard',
      (tester) async {
    await pumpManager(tester);

    expect(find.text('Secure Hibernate'), findsOneWidget);
    expect(find.text('Installation Wizard'), findsOneWidget);
    expect(find.text('Test backend · Mock data'), findsOneWidget);
    expect(find.text('Overview'), findsNothing);
    for (final step in [
      'Check',
      'Options',
      'Verify',
      'MOK',
      'Install',
      'Boot',
      'TPM'
    ]) {
      expect(find.text(step), findsOneWidget);
    }
    expect(find.byTooltip('Minimize'), findsOneWidget);
    expect(find.byTooltip('Maximize or restore'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('completed setup does not flash the first-run wizard',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _DelayedCompletedBackend();

    await tester.pumpWidget(
      SecureHibernateManagerApp(translations: translations, backend: backend),
    );
    await tester.pump();

    expect(find.byType(AppSidebar), findsNothing);
    expect(find.text('Installation Wizard'), findsNothing);

    backend.progress.complete(
      const SetupProgress(checkpoint: null, completed: true),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppSidebar), findsOneWidget);
  });

  testWidgets('finishing setup exposes the complete manager sidebar',
      (tester) async {
    await pumpManager(tester);
    await completeMockSetup(tester);

    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Installation Wizard'), findsWidgets);
    expect(find.text('Kernels & Updates'), findsWidgets);
    expect(find.text('Security & Hardware'), findsWidgets);
    expect(find.text('Preferences'), findsWidgets);
    expect(find.text('Diagnostics'), findsNothing);
  });

  testWidgets('Manager updates have overview and available-update entries',
      (tester) async {
    await pumpManager(tester);
    await completeMockSetup(tester);

    final overviewEntry =
        find.byKey(const ValueKey('overview-manager-updates'));
    expect(overviewEntry, findsOneWidget);
    expect(find.text('Manager Updates'), findsOneWidget);
    await tester.ensureVisible(overviewEntry);
    await tester.tap(overviewEntry);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Available Updates'), findsOneWidget);
    final softwareEntry = find.byKey(const ValueKey('manager-software-update'));
    expect(softwareEntry, findsOneWidget);
    await tester.ensureVisible(softwareEntry);
    await tester.pump();
    expect(find.text('Manager Software:'), findsOneWidget);
    expect(find.text('Independent release channel'), findsOneWidget);
  });

  testWidgets('manager surface keeps one fixed frame across pages',
      (tester) async {
    await pumpManager(tester);
    await completeMockSetup(tester);

    const surfaceKey = ValueKey('manager-main-surface');
    final overviewSurface = tester.getRect(find.byKey(surfaceKey));
    final overviewHeadingTop = tester.getTopLeft(find.text('Overview').last).dy;

    await tester.tap(
      find.descendant(
        of: find.byType(AppSidebar),
        matching: find.text('Kernels & Updates'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    final kernelsSurface = tester.getRect(find.byKey(surfaceKey));
    final kernelsHeadingTop =
        tester.getTopLeft(find.text('Kernels & Updates').last).dy;
    expect(kernelsSurface, overviewSurface);
    expect(kernelsHeadingTop, overviewHeadingTop);
    expect(kernelsSurface.top, lessThan(kernelsHeadingTop));
  });

  testWidgets('manager navigation, theme, advanced mode, and language work',
      (tester) async {
    await pumpManager(tester);
    await completeMockSetup(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(AppSidebar),
        matching: find.text('Preferences'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('theme-dark')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    await tester.ensureVisible(find.byType(AppSwitch));
    await tester.tap(find.byType(AppSwitch));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Diagnostics'), findsWidgets);

    await tester.ensureVisible(find.text('English (United States)'));
    await tester.tap(find.text('English (United States)'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('简体中文'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('偏好设置'), findsWidgets);
    expect(find.text('高级模式'), findsOneWidget);
  });

  testWidgets('Polkit cancellation is surfaced by the global notice overlay',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final manager = ManagerController(
      translations,
      backend: const _CancelledManagerBackend(),
    );
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildManagerTheme(Brightness.light),
        home: ManagerScope(
          controller: manager,
          child: const ManagerShell(
            firstRun: true,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Authorization cancelled'), findsOneWidget);
    expect(
      find.text(
        'The privileged action was cancelled or denied. No system changes were made.',
      ),
      findsOneWidget,
    );
    manager.dismissNotice(manager.notices.single.id);
    await tester.pump();
  });

  testWidgets('system checks expose inline reason and remediation help',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: const _CancelledManagerBackend(luks: false),
      ),
    );
    await tester.pumpAndSettle();

    for (final tooltip in [
      'Why: this project requires Linux 7.0.0 or newer. How: install and boot a supported Ubuntu kernel before continuing.',
      'Why: the project-signed kernel is verified through UEFI Secure Boot. How: enable Secure Boot in firmware settings, then check again.',
      'Why: Kernel Lockdown prevents privileged software from bypassing the Secure Boot trust chain through low-level kernel access. How: enable Secure Boot, then boot an official Ubuntu kernel or a project-signed kernel that supports Lockdown and check again.',
      'Why: hibernation writes session memory, application data, and potentially key material to Swap. Without LUKS, an offline party can read that image. How: use an encrypted Ubuntu installation or migrate the root volume manually. Installation may continue without it.',
      'Why: suspend-to-disk needs a disk-backed Swap file at least as large as physical memory. How: select Fix Automatically to create or replace /swap.img safely.',
      'Why: an official Ubuntu kernel provides an independent recovery boot path. How: install the Ubuntu HWE kernel meta-package before continuing.',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
    expect(find.text('Lockdown Mode'), findsOneWidget);
    expect(find.text('Not Encrypted · Recommended'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('insufficient hibernation swap offers automatic repair',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: const _CancelledManagerBackend(hibernatePartition: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fix Automatically'), findsOneWidget);
  });

  testWidgets('check authorization polls past a stale terminal snapshot',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _StartCheckRaceBackend();

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: backend,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(find.text('Check Again'), findsOneWidget);
    await tester.tap(find.text('Check Again'));
    await tester.pump();
    expect(find.text('Indexing'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 550));
    expect(find.text('10%'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('MOK resume ignores a stale stopped download state',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _MokResumeWithStaleDownloadBackend();

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: backend,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enroll Project MOK'), findsOneWidget);
    expect(find.text('Prepare Enrollment'), findsOneWidget);
    expect(find.text('14%'), findsNothing);
    expect(
      find.byKey(const ValueKey('wizard-action-transfer-fill')),
      findsNothing,
    );
    expect(backend.snapshotReads, 1);
    expect(backend.mokInspections, 1);

    await tester.pump(const Duration(milliseconds: 1100));
    expect(backend.snapshotReads, 1);
    expect(backend.mokInspections, 1);
  });

  testWidgets('native startup inspects MOK once after the first frame',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _StartupMokBackend();

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: backend,
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.mokInspections, 1);
    expect(find.text('Protected'), findsOneWidget);
  });

  testWidgets('package verification failure is shown on the matching row',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _FixedUpdaterBackend(testUpdaterStatus(
      status: 'check-failed',
      checkedAt: '2026-08-03T03:00:00Z',
      checkFailedPhase: 'verifying-packages',
      lastCheckError: 'Package signature verification failed',
    ));

    await tester.pumpWidget(
      SecureHibernateManagerApp(translations: translations, backend: backend),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    final rows = tester.widgetList<DetailRow>(find.byType(DetailRow));
    final byLabel = {for (final row in rows) row.label: row};
    expect(byLabel['Latest Project Release']?.status, StatusKind.ok);
    expect(byLabel['Package Download']?.status, StatusKind.ok);
    expect(byLabel['Signed Release Manifest']?.status, StatusKind.ok);
    expect(
      byLabel['EFI image and module signatures']?.status,
      StatusKind.error,
    );
    expect(
      byLabel['EFI image and module signatures']?.description,
      'Package signature verification failed',
    );
    expect(byLabel['Ubuntu HWE version authorization']?.status,
        StatusKind.pending);
    expect(find.text('Package signature verification failed'), findsOneWidget);
  });

  testWidgets('legacy MOK password requires explicit regeneration',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;
    final backend = _LegacyMokPasswordBackend();

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: backend,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Regenerate Password'), findsOneWidget);
    expect(find.text('Password update required'), findsOneWidget);
    expect(find.text('Restart required'), findsNothing);
    expect(find.byIcon(LucideIcons.lock), findsOneWidget);
    final legacyPassword = tester.widget<Text>(find.text('Sensitive123'));
    expect(legacyPassword.style?.fontFamily, 'Ubuntu');
    expect(legacyPassword.style?.fontWeight, FontWeight.w700);

    await tester.tap(find.text('Regenerate Password'));
    await tester.pumpAndSettle();

    expect(backend.prepareRequests, 1);
    expect(find.text('abc23456'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.byIcon(LucideIcons.lock), findsOneWidget);
  });

  testWidgets('preflight help dialog renders and can be closed',
      (tester) async {
    final translations = _translations ?? await TranslationCatalog.load();
    _translations = translations;

    await tester.pumpWidget(
      SecureHibernateManagerApp(
        translations: translations,
        backend: const _CancelledManagerBackend(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Boot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get Help'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('preflight-dialog')),
      findsOneWidget,
    );
    expect(find.text('System Requirement Log'), findsOneWidget);
    expect(find.textContaining('secure-hibernate-manager preflight'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preflight-dialog-close')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('preflight-dialog')),
      findsNothing,
    );

    await tester.tap(find.text('Get Help'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 200));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('preflight-dialog')),
      findsNothing,
    );
  });
}
