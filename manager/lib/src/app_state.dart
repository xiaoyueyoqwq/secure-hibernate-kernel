import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend.dart';
import 'desktop_notifications.dart';
import 'manager_updates.dart';
import 'translations.dart';

export 'backend.dart'
    show
        BackendConnection,
        ExportResult,
        ExportStatus,
        InstallPhase,
        InstallProgress,
        KernelInfo,
        KernelStatus,
        ManagerActionData,
        ManagerActionRequest,
        ManagerActionResult,
        ManagerActionStatus,
        ManagerActionType,
        ManagerBackend,
        PreflightDiagnostic,
        ProjectMokInspection,
        ProjectMokStatus,
        SetupCheckpoint,
        SetupProgress,
        SystemActionResult,
        SystemActionStatus,
        SystemSnapshot,
        SystemStatus,
        UpdateControllerStatus,
        UpdatePolicy;
export 'manager_updates.dart'
    show
        FixedManagerUpdateChecker,
        ManagerUpdateChecker,
        ManagerUpdateInfo,
        ManagerUpdateState,
        managerCurrentVersion;
export 'desktop_notifications.dart'
    show
        DesktopUpdateKind,
        ManagerNotificationService,
        NoopManagerNotificationService;

enum ManagerPage { overview, wizard, kernels, security, settings, diagnostics }

enum ManagerNoticeType { info, success, warning, error, loading }

const _kernelCheckPollInterval = Duration(seconds: 1);
const _kernelCheckMonitorTimeout = Duration(hours: 2);
const _kernelCheckInactiveGracePolls = 10;
const _kernelCheckRunningStatuses = {
  'indexing',
  'downloading',
  'verifying-manifest',
  'verifying-packages',
  'authorizing-version',
};

Future<void> _noopWindowFocuser() async {}

class ManagerNotice {
  const ManagerNotice({
    required this.id,
    required this.type,
    required this.title,
    this.description,
  });

  final String id;
  final ManagerNoticeType type;
  final String title;
  final String? description;
}

class ManagerController extends ChangeNotifier {
  ManagerController(
    this.translations, {
    this.backend,
    ManagerUpdateChecker? updateChecker,
    ManagerNotificationService? notificationService,
    Future<void> Function(String)? releaseOpener,
    Future<void> Function()? windowFocuser,
    ManagerPage initialPage = ManagerPage.overview,
  })  : _releaseOpener = releaseOpener ?? openManagerRelease,
        _notificationService =
            notificationService ?? const NoopManagerNotificationService(),
        _windowFocuser = windowFocuser ?? _noopWindowFocuser,
        activePage = initialPage,
        language = AppLanguage.fromLocale(
          PlatformDispatcher.instance.locale.languageCode,
          PlatformDispatcher.instance.locale.countryCode,
          PlatformDispatcher.instance.locale.scriptCode,
        ),
        backendConnection = backend == null
            ? BackendConnection.mock
            : BackendConnection.loading,
        _updateChecker = updateChecker ??
            (backend == null
                ? const FixedManagerUpdateChecker()
                : const GitHubManagerUpdateChecker()) {
    if (backend == null) {
      deviceName = 'InspironBook';
      ubuntuVersion = 'Ubuntu 26.04 LTS';
      secureBoot = true;
      luks = true;
      hibernationCapacity = true;
      grubConfigured = true;
      headersInstalled = true;
      snapshotLoaded = true;
      kernels = const [
        KernelInfo(
          id: 'installed-7.0.12-28-hibernate',
          version: '7.0.12-28-hibernate',
          project: true,
          status: KernelStatus.active,
        ),
        KernelInfo(
          id: 'installed-7.0.12-ubuntu28-s4lockdown',
          version: '7.0.12-ubuntu28-s4lockdown',
          project: true,
          status: KernelStatus.installed,
        ),
        KernelInfo(
          id: 'installed-7.0.0-28-generic',
          version: '7.0.0-28-generic',
          project: false,
          status: KernelStatus.installed,
        ),
      ];
      logs.add('[System] Flutter preview is using deterministic mock data');
      managerUpdate = const ManagerUpdateInfo(
        state: ManagerUpdateState.current,
        currentVersion: managerCurrentVersion,
        latestVersion: managerCurrentVersion,
      );
    }
    unawaited(_initialize());
  }

  final TranslationCatalog translations;
  final ManagerBackend? backend;
  final ManagerUpdateChecker _updateChecker;
  final ManagerNotificationService _notificationService;
  final Future<void> Function(String) _releaseOpener;
  final Future<void> Function() _windowFocuser;
  SharedPreferences? _preferences;
  bool _disposed = false;
  bool _languageChanged = false;
  bool _themeChanged = false;
  bool _advancedModeChanged = false;

  AppLanguage language;
  ThemeMode themeMode = ThemeMode.system;
  ManagerPage activePage;
  BackendConnection backendConnection;
  bool setupComplete = false;
  bool setupProgressLoaded = false;
  bool advancedMode = false;
  bool configureTpm = true;
  UpdatePolicy updatePolicy = UpdatePolicy.checkAndNotify;
  int projectKernelHistory = 2;
  ProjectMokStatus projectMokStatus = ProjectMokStatus.unknown;
  String? projectMokFingerprint;
  String? mokOneTimePassword;
  String deviceName = '';
  String ubuntuVersion = '';
  bool secureBoot = false;
  bool lockdown = false;
  bool luks = false;
  bool tpmConfigured = false;
  bool hibernationCapacity = false;
  bool grubConfigured = false;
  bool headersInstalled = false;
  bool snapshotLoaded = false;
  SetupCheckpoint? setupCheckpoint;
  int currentWizardStep = 0;
  int furthestWizardStep = 0;
  List<PreflightDiagnostic> preflightDiagnostics = const [];
  List<String> collectorWarnings = const [];
  UpdateControllerStatus updater = const UpdateControllerStatus.empty();
  ManagerUpdateInfo managerUpdate = const ManagerUpdateInfo.unknown();
  final List<ManagerNotice> notices = <ManagerNotice>[];
  final List<String> logs = <String>[
    '[System] Application initialized',
  ];
  List<KernelInfo> kernels = const [];
  final Map<String, Timer> _noticeTimers = <String, Timer>{};
  int _noticeCounter = 0;
  Future<ProjectMokInspection>? _activeMokInspection;
  Future<void>? _activeManagerUpdateCheck;
  String? _notifiedManagerVersion;
  String? _notifiedKernelRelease;
  Future<ManagerActionResult>? _activeKernelCheckStart;
  Future<void>? _activeKernelCheckMonitor;
  Timer? _kernelCheckPollTimer;
  Completer<void>? _kernelCheckPollWait;
  bool _startupMokInspectionAttempted = false;
  bool _startupKernelCheckAttempted = false;

  AppMessages get t => translations.messages(language);

  KernelInfo get activeKernel =>
      kernels
          .where((kernel) => kernel.status == KernelStatus.active)
          .firstOrNull ??
      const KernelInfo(
        id: 'unknown',
        version: '',
        project: false,
        status: KernelStatus.active,
      );

  bool get officialFallbackInstalled => kernels.any(
        (kernel) => !kernel.project && kernel.status != KernelStatus.available,
      );

  bool get native => backend != null;

  bool get runningKernelSupported {
    return kernelReleaseMeetsMinimum(activeKernel.version);
  }

  Future<void> _initialize() async {
    await _loadPreferences();
    if (backend == null || _disposed) {
      setupProgressLoaded = true;
      notifyListeners();
      return;
    }
    try {
      final progress = await backend!.getSetupProgress();
      setupCheckpoint = progress.checkpoint;
      setupComplete = progress.completed;
      setupProgressLoaded = true;
      if (!setupComplete && progress.checkpoint != null) {
        currentWizardStep =
            progress.checkpoint == SetupCheckpoint.awaitingMokEnrollment
                ? 3
                : 5;
        furthestWizardStep = currentWizardStep;
      }
      await refreshSnapshot();
      unawaited(checkManagerUpdate());
      if (backendConnection != BackendConnection.error) {
        backendConnection = BackendConnection.native;
      }
      addLog('[System] Native Manager backend connected');
      // Defer fixed Helper startup actions until the first frame is visible so
      // Polkit can present authorization without racing wizard recovery UI.
      // Start the kernel check before MOK inspection to serialize the prompts.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && !_startupMokInspectionAttempted) {
          unawaited(_runStartupNativeActions());
        }
      });
    } on Object catch (error) {
      setupProgressLoaded = true;
      backendConnection = BackendConnection.error;
      addLog('[Error] Native Manager backend unavailable: $error');
      notifyListeners();
    }
  }

  Future<void> _loadPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (_disposed) return;
    _preferences = preferences;
    final storedLanguage =
        preferences.getString('secure-hibernate-manager-language');
    if (!_languageChanged && storedLanguage != null) {
      language = AppLanguage.values.firstWhere(
        (value) => value.code == storedLanguage,
        orElse: () => language,
      );
    }
    final storedTheme = preferences.getString('secure-hibernate-manager-theme');
    if (!_themeChanged && storedTheme != null) {
      themeMode = ThemeMode.values.firstWhere(
        (value) => value.name == storedTheme,
        orElse: () => themeMode,
      );
    }
    if (!_advancedModeChanged) {
      advancedMode = preferences.getBool('secure-hibernate-manager-advanced') ??
          advancedMode;
    }
    if (_languageChanged) {
      unawaited(preferences.setString(
        'secure-hibernate-manager-language',
        language.code,
      ));
    }
    if (_themeChanged) {
      unawaited(preferences.setString(
        'secure-hibernate-manager-theme',
        themeMode.name,
      ));
    }
    if (_advancedModeChanged) {
      unawaited(preferences.setBool(
        'secure-hibernate-manager-advanced',
        advancedMode,
      ));
    }
    notifyListeners();
  }

  void setLanguage(AppLanguage value) {
    _languageChanged = true;
    language = value;
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.setString(
        'secure-hibernate-manager-language',
        value.code,
      ));
    }
    notifyListeners();
  }

  void setThemeMode(ThemeMode value) {
    _themeChanged = true;
    themeMode = value;
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.setString(
        'secure-hibernate-manager-theme',
        value.name,
      ));
    }
    notifyListeners();
  }

  void setPage(ManagerPage value) {
    activePage = value;
    notifyListeners();
  }

  void setAdvancedMode(bool value) {
    _advancedModeChanged = true;
    advancedMode = value;
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.setBool(
        'secure-hibernate-manager-advanced',
        value,
      ));
    }
    if (!value && activePage == ManagerPage.diagnostics) {
      activePage = ManagerPage.settings;
    }
    notifyListeners();
  }

  void setUpdatePolicy(UpdatePolicy value) {
    updatePolicy = value;
    if (backend == null) {
      addLog(
          '[System] Changed test-backend updater policy to ${value.wireValue}');
    }
    notifyListeners();
  }

  Future<ManagerActionResult?> changeUpdatePolicy(UpdatePolicy value) async {
    if (backend == null) {
      setUpdatePolicy(value);
      return null;
    }
    final result = await runManagerAction(
      ManagerActionRequest(ManagerActionType.setPolicy, policy: value),
    );
    if (result.status == ManagerActionStatus.success) await refreshSnapshot();
    return result;
  }

  Future<ManagerActionResult?> changeProjectKernelHistory(int value) async {
    if (value < 1 || value > 3) {
      throw ArgumentError.value(value, 'value', 'must be between 1 and 3');
    }
    if (backend == null) {
      projectKernelHistory = value;
      addLog(
        '[System] Changed test-backend project kernel history to $value',
      );
      notifyListeners();
      return null;
    }
    final result = await runManagerAction(
      ManagerActionRequest(
        ManagerActionType.setKernelRetention,
        projectKernelHistory: value,
      ),
    );
    if (result.status == ManagerActionStatus.success) await refreshSnapshot();
    return result;
  }

  void setConfigureTpm(bool value) {
    configureTpm = luks && value;
    notifyListeners();
  }

  void selectWizardStep(int value) {
    currentWizardStep = value.clamp(0, 6);
    furthestWizardStep = currentWizardStep > furthestWizardStep
        ? currentWizardStep
        : furthestWizardStep;
    notifyListeners();
  }

  void advanceWizard() {
    if (currentWizardStep < 6) {
      selectWizardStep(currentWizardStep + 1);
    } else {
      setupComplete = true;
      activePage = ManagerPage.overview;
      currentWizardStep = 0;
      furthestWizardStep = 0;
      notifyListeners();
    }
  }

  Future<SystemSnapshot> refreshSnapshot() async {
    if (backend == null) {
      notifyListeners();
      return _mockSnapshot();
    }
    final snapshot = await backend!.getSnapshot();
    _applySnapshot(snapshot);
    _notifyKernelUpdateIfAvailable();
    backendConnection = BackendConnection.native;
    notifyListeners();
    return snapshot;
  }

  Future<void> checkManagerUpdate() {
    final active = _activeManagerUpdateCheck;
    if (active != null) return active;
    final check = _performManagerUpdateCheck();
    _activeManagerUpdateCheck = check;
    return check.whenComplete(() {
      if (identical(_activeManagerUpdateCheck, check)) {
        _activeManagerUpdateCheck = null;
      }
    });
  }

  Future<void> _performManagerUpdateCheck() async {
    managerUpdate = ManagerUpdateInfo(
      state: ManagerUpdateState.checking,
      currentVersion: managerCurrentVersion,
      latestVersion: managerUpdate.latestVersion,
    );
    notifyListeners();
    try {
      final result = await _updateChecker.check(managerCurrentVersion);
      if (_disposed) return;
      managerUpdate = result;
      _notifyManagerUpdateIfAvailable();
    } on Object catch (error) {
      if (_disposed) return;
      managerUpdate = ManagerUpdateInfo(
        state: ManagerUpdateState.error,
        currentVersion: managerCurrentVersion,
        error: error.toString(),
      );
    }
    notifyListeners();
  }

  void _notifyManagerUpdateIfAvailable() {
    final version = managerUpdate.latestVersion;
    if (backend == null ||
        managerUpdate.state != ManagerUpdateState.available ||
        version == null ||
        version == _notifiedManagerVersion) {
      return;
    }
    _notifiedManagerVersion = version;
    unawaited(_showUpdateNotification(
      kind: DesktopUpdateKind.manager,
      version: version,
      title: t.text('notifications.managerUpdateTitle'),
      body: t.text('notifications.managerUpdateBody', {'version': version}),
    ));
  }

  void _notifyKernelUpdateIfAvailable() {
    final release = updater.availableKernelRelease;
    if (backend == null ||
        release == null ||
        release == _notifiedKernelRelease) {
      return;
    }
    _notifiedKernelRelease = release;
    unawaited(_showUpdateNotification(
      kind: DesktopUpdateKind.kernel,
      version: release,
      title: t.text('notifications.kernelUpdateTitle'),
      body: t.text('notifications.kernelUpdateBody', {'version': release}),
    ));
  }

  Future<void> _showUpdateNotification({
    required DesktopUpdateKind kind,
    required String version,
    required String title,
    required String body,
  }) async {
    try {
      await _notificationService.showUpdate(
        kind: kind,
        version: version,
        title: title,
        body: body,
        actionLabel: t.text('notifications.viewUpdates'),
        onOpen: () async {
          if (!_disposed) await openUpdatesPage();
        },
      );
    } on Object catch (error) {
      if (kind == DesktopUpdateKind.manager &&
          _notifiedManagerVersion == version) {
        _notifiedManagerVersion = null;
      } else if (kind == DesktopUpdateKind.kernel &&
          _notifiedKernelRelease == version) {
        _notifiedKernelRelease = null;
      }
      if (!_disposed) {
        logs.add('[Error] Desktop update notification failed: $error');
        notifyListeners();
      }
    }
  }

  Future<void> openUpdatesPage() async {
    setPage(ManagerPage.kernels);
    await _windowFocuser();
    if (backend != null && !_disposed) {
      unawaited(checkManagerUpdate());
      unawaited(_refreshSnapshotAfterActivation());
    }
  }

  Future<void> _refreshSnapshotAfterActivation() async {
    try {
      await refreshSnapshot();
    } on Object catch (error) {
      if (!_disposed) {
        logs.add('[Error] Update status refresh failed: $error');
        notifyListeners();
      }
    }
  }

  Future<void> _runStartupNativeActions() async {
    if (!_startupKernelCheckAttempted &&
        !_startupMokInspectionAttempted &&
        _activeKernelCheckStart == null &&
        _activeMokInspection == null &&
        backend != null &&
        setupComplete &&
        updater.controllerInstalled &&
        updater.policy != UpdatePolicy.manual) {
      await _performCombinedStartupRefresh();
      return;
    }
    await _checkKernelUpdateOnStartup();
    if (!_disposed && !_startupMokInspectionAttempted) {
      await inspectProjectMok();
    }
  }

  Future<void> _performCombinedStartupRefresh() async {
    _startupKernelCheckAttempted = true;
    _startupMokInspectionAttempted = true;
    final baselineStatus = updater.lastCheckStatus;
    final baselineCheckedAt = updater.lastCheckedAt;
    projectMokStatus = ProjectMokStatus.pendingConfirmation;
    notifyListeners();

    const request = ManagerActionRequest(ManagerActionType.startupRefresh);
    final action = backend!.runManagerAction(request);
    final kernelStart = action.then(
      (result) => ManagerActionResult(
        action: ManagerActionType.startCheck,
        status: result.status,
        error: result.error,
        data: const ManagerActionData(),
      ),
    );
    final mokInspection = action.then(projectMokInspectionFromActionResult);
    _activeKernelCheckStart = kernelStart;
    _activeMokInspection = mokInspection;
    try {
      final result = await action;
      if (_disposed) return;
      _publishActionResult(request, result);
      final inspection = await mokInspection;
      if (_disposed) return;
      _applyProjectMokInspection(inspection, publishFailure: false);
      if (result.status == ManagerActionStatus.success) {
        _startKernelCheckMonitor(baselineStatus, baselineCheckedAt);
      }
    } finally {
      if (identical(_activeKernelCheckStart, kernelStart)) {
        _activeKernelCheckStart = null;
      }
      if (identical(_activeMokInspection, mokInspection)) {
        _activeMokInspection = null;
      }
    }
  }

  Future<void> _checkKernelUpdateOnStartup() async {
    if (_startupKernelCheckAttempted) return;
    _startupKernelCheckAttempted = true;
    if (!setupComplete ||
        !updater.controllerInstalled ||
        updater.policy == UpdatePolicy.manual) {
      return;
    }
    await startKernelUpdateCheck();
  }

  Future<ManagerActionResult> startKernelUpdateCheck() {
    final active = _activeKernelCheckStart;
    if (active != null) return active;
    final start = _performKernelUpdateCheckStart();
    _activeKernelCheckStart = start;
    return start.whenComplete(() {
      if (identical(_activeKernelCheckStart, start)) {
        _activeKernelCheckStart = null;
      }
    });
  }

  Future<ManagerActionResult> _performKernelUpdateCheckStart() async {
    if (backend == null) {
      return const ManagerActionResult(
        action: ManagerActionType.startCheck,
        status: ManagerActionStatus.error,
        error: 'Kernel update checks require the native Manager backend',
        data: ManagerActionData(),
      );
    }
    final baselineStatus = updater.lastCheckStatus;
    final baselineCheckedAt = updater.lastCheckedAt;
    if (_activeKernelCheckMonitor != null || updater.checkServiceActive) {
      _startKernelCheckMonitor(baselineStatus, baselineCheckedAt);
      return const ManagerActionResult(
        action: ManagerActionType.startCheck,
        status: ManagerActionStatus.success,
        error: null,
        data: ManagerActionData(),
      );
    }
    final result = await runManagerAction(
      const ManagerActionRequest(ManagerActionType.startCheck),
    );
    if (result.status == ManagerActionStatus.success && !_disposed) {
      _startKernelCheckMonitor(baselineStatus, baselineCheckedAt);
    }
    return result;
  }

  void _startKernelCheckMonitor(
    String? baselineStatus,
    String? baselineCheckedAt,
  ) {
    if (_activeKernelCheckMonitor != null) return;
    late final Future<void> monitor;
    monitor =
        _monitorKernelCheck(baselineStatus, baselineCheckedAt).whenComplete(() {
      if (identical(_activeKernelCheckMonitor, monitor)) {
        _activeKernelCheckMonitor = null;
      }
    });
    _activeKernelCheckMonitor = monitor;
  }

  Future<void> _monitorKernelCheck(
    String? baselineStatus,
    String? baselineCheckedAt,
  ) async {
    final deadline = DateTime.now().add(_kernelCheckMonitorTimeout);
    var inactivePollsRemaining = _kernelCheckInactiveGracePolls;
    var consecutiveReadFailures = 0;
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      await _waitForKernelCheckPoll();
      if (_disposed) return;
      try {
        await refreshSnapshot();
        consecutiveReadFailures = 0;
      } on Object catch (error) {
        consecutiveReadFailures += 1;
        if (consecutiveReadFailures >= 3) {
          addLog('[Error] Kernel update status refresh failed: $error');
          return;
        }
        continue;
      }
      final stateAdvanced = updater.lastCheckStatus != baselineStatus ||
          updater.lastCheckedAt != baselineCheckedAt;
      if (updater.checkServiceActive) {
        inactivePollsRemaining = _kernelCheckInactiveGracePolls;
        continue;
      }
      if (stateAdvanced &&
          !_kernelCheckRunningStatuses.contains(updater.lastCheckStatus)) {
        return;
      }
      inactivePollsRemaining -= 1;
      if (inactivePollsRemaining <= 0) {
        addLog(
          '[Warning] Kernel update check did not publish a terminal state',
        );
        return;
      }
    }
    if (!_disposed) {
      addLog('[Warning] Kernel update check status monitoring timed out');
    }
  }

  Future<void> _waitForKernelCheckPoll() {
    final wait = Completer<void>();
    late final Timer timer;
    timer = Timer(_kernelCheckPollInterval, () {
      if (identical(_kernelCheckPollTimer, timer)) {
        _kernelCheckPollTimer = null;
        _kernelCheckPollWait = null;
      }
      wait.complete();
    });
    _kernelCheckPollTimer = timer;
    _kernelCheckPollWait = wait;
    return wait.future;
  }

  void _cancelKernelCheckPoll() {
    _kernelCheckPollTimer?.cancel();
    _kernelCheckPollTimer = null;
    final wait = _kernelCheckPollWait;
    _kernelCheckPollWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  Future<void> openManagerUpdateRelease() async {
    final releaseUrl = managerUpdate.releaseUrl;
    if (managerUpdate.state != ManagerUpdateState.available ||
        releaseUrl == null) {
      addLog('[Error] Manager update: no trusted Release is available');
      return;
    }
    try {
      await _releaseOpener(releaseUrl);
    } on Object catch (error) {
      addLog('[Error] Manager update: unable to open Release: $error');
      addNotice(
        type: ManagerNoticeType.error,
        title: t.text('alerts.managerUpdateOpenFailedTitle'),
        description: t.text('alerts.managerUpdateOpenFailedDescription'),
      );
    }
  }

  Future<InstallProgress> getInstallProgress() async {
    if (backend == null) return const InstallProgress.idle();
    return backend!.getInstallProgress();
  }

  void _applySnapshot(SystemSnapshot snapshot) {
    final status = snapshot.systemStatus;
    deviceName = status.deviceName;
    ubuntuVersion = status.ubuntuVersion;
    secureBoot = status.secureBoot;
    lockdown = status.lockdown;
    luks = status.luks;
    if (!luks) configureTpm = false;
    tpmConfigured = status.tpmConfigured;
    hibernationCapacity = status.hibernatePartition;
    grubConfigured = status.grubUpdated;
    headersInstalled = status.projectHeadersInstalled;
    kernels = List.unmodifiable(snapshot.kernels);
    updater = snapshot.updater;
    updatePolicy = snapshot.updater.policy;
    projectKernelHistory = snapshot.updater.projectKernelHistory;
    preflightDiagnostics = List.unmodifiable(snapshot.preflightDiagnostics);
    collectorWarnings = List.unmodifiable(snapshot.warnings);
    snapshotLoaded = true;
  }

  Future<ProjectMokInspection> inspectProjectMok() {
    _startupMokInspectionAttempted = true;
    final active = _activeMokInspection;
    if (active != null) return active;
    final inspection = _performProjectMokInspection();
    _activeMokInspection = inspection;
    return inspection.whenComplete(() {
      if (identical(_activeMokInspection, inspection)) {
        _activeMokInspection = null;
      }
    });
  }

  Future<ProjectMokInspection> _performProjectMokInspection() async {
    if (backend == null) {
      projectMokStatus = ProjectMokStatus.missing;
      addLog('[System] Test-backend MOK result: missing');
      notifyListeners();
      return ProjectMokInspection(
        status: projectMokStatus,
        fingerprintSha256: projectMokFingerprint,
        error: null,
        oneTimePassword: null,
      );
    }
    projectMokStatus = ProjectMokStatus.pendingConfirmation;
    notifyListeners();
    final inspection = await backend!.inspectProjectMok();
    _applyProjectMokInspection(inspection);
    return inspection;
  }

  void _applyProjectMokInspection(
    ProjectMokInspection inspection, {
    bool publishFailure = true,
  }) {
    projectMokStatus = inspection.status == ProjectMokStatus.cancelled
        ? ProjectMokStatus.unknown
        : inspection.status;
    projectMokFingerprint = inspection.fingerprintSha256;
    mokOneTimePassword = inspection.oneTimePassword;
    if (inspection.status == ProjectMokStatus.enrolled) {
      addLog('[System] Project MOK is enrolled');
    } else if (inspection.status == ProjectMokStatus.missing) {
      addLog('[System] Project MOK is not enrolled');
    } else if (inspection.status == ProjectMokStatus.pendingEnrollment) {
      addLog('[System] Project MOK enrollment is pending');
    } else if (publishFailure &&
        inspection.status == ProjectMokStatus.cancelled) {
      _publishAuthorizationDenied();
    } else if (publishFailure && inspection.error != null) {
      _publishPrivilegedFailure('inspect-mok', inspection.error!);
    }
    notifyListeners();
  }

  Future<ManagerActionResult> runManagerAction(
    ManagerActionRequest request,
  ) async {
    if (backend == null) {
      final result = ManagerActionResult(
        action: request.action,
        status: ManagerActionStatus.error,
        error: 'Privileged actions are unavailable with the test backend',
        data: const ManagerActionData(),
      );
      _publishActionResult(request, result);
      return result;
    }
    final result = await backend!.runManagerAction(request);
    _publishActionResult(request, result);
    if (result.action == ManagerActionType.prepareMok &&
        result.status == ManagerActionStatus.success) {
      projectMokStatus = result.data.mokStatus == 'enrolled'
          ? ProjectMokStatus.enrolled
          : ProjectMokStatus.pendingEnrollment;
      projectMokFingerprint = result.data.fingerprintSha256;
      mokOneTimePassword = result.data.oneTimePassword;
      notifyListeners();
    }
    if (result.action == ManagerActionType.cancelMok &&
        result.status == ManagerActionStatus.success) {
      projectMokStatus = ProjectMokStatus.unknown;
      mokOneTimePassword = null;
      notifyListeners();
    }
    return result;
  }

  Future<void> saveSetupCheckpoint(SetupCheckpoint checkpoint) async {
    if (backend == null) {
      setupCheckpoint = checkpoint;
      notifyListeners();
      return;
    }
    final progress = await backend!.saveSetupCheckpoint(checkpoint);
    setupCheckpoint = progress.checkpoint;
    notifyListeners();
  }

  Future<void> clearSetupCheckpoint() async {
    if (backend == null) {
      setupCheckpoint = null;
      notifyListeners();
      return;
    }
    final progress = await backend!.clearSetupCheckpoint();
    setupCheckpoint = progress.checkpoint;
    notifyListeners();
  }

  Future<SystemActionResult> restartForSetup(SetupCheckpoint checkpoint) async {
    if (backend == null) {
      return const SystemActionResult(
        status: SystemActionStatus.error,
        error: 'Restart is unavailable with the test backend',
      );
    }
    final result = await backend!.restartForSetup(checkpoint);
    if (result.status == SystemActionStatus.started) {
      setupCheckpoint = checkpoint;
      notifyListeners();
    } else if (result.status == SystemActionStatus.cancelled) {
      _publishAuthorizationDenied();
    } else if (result.error != null) {
      _publishPrivilegedFailure(t.text('common.restart'), result.error!);
    }
    return result;
  }

  Future<ExportResult> exportDiagnostics() async {
    if (backend == null) {
      return const ExportResult(
        status: ExportStatus.error,
        path: null,
        error: 'Diagnostic export is unavailable with the test backend',
      );
    }
    return backend!.exportDiagnostics();
  }

  Future<void> completeNativeSetup() async {
    if (backend == null) {
      setupComplete = true;
      activePage = ManagerPage.overview;
      currentWizardStep = 0;
      furthestWizardStep = 0;
      notifyListeners();
      return;
    }
    final progress = await backend!.completeSetup(configureTpm);
    setupComplete = progress.completed;
    setupCheckpoint = progress.checkpoint;
    activePage = ManagerPage.overview;
    currentWizardStep = 0;
    furthestWizardStep = 0;
    notifyListeners();
  }

  void addLog(String message) {
    logs.add(message);
    notifyListeners();
  }

  void addNotice({
    required ManagerNoticeType type,
    required String title,
    String? description,
    Duration duration = const Duration(seconds: 6),
  }) {
    final id = 'notice-${_noticeCounter++}';
    notices.insert(
      0,
      ManagerNotice(
        id: id,
        type: type,
        title: title,
        description: description,
      ),
    );
    notifyListeners();
    if (duration != Duration.zero) {
      _noticeTimers[id] = Timer(duration, () => dismissNotice(id));
    }
  }

  void dismissNotice(String id) {
    _noticeTimers.remove(id)?.cancel();
    final before = notices.length;
    notices.removeWhere((notice) => notice.id == id);
    if (notices.length != before) notifyListeners();
  }

  void _publishActionResult(
    ManagerActionRequest request,
    ManagerActionResult result,
  ) {
    if (result.status == ManagerActionStatus.cancelled) {
      _publishAuthorizationDenied(action: request.action.wireValue);
    } else if (result.status == ManagerActionStatus.error) {
      _publishPrivilegedFailure(
        request.action.wireValue,
        result.error ?? t.text('alerts.unknownPrivilegedError'),
      );
    }
  }

  void _publishAuthorizationDenied({String? action}) {
    addLog(
      '[Warning] ${action ?? 'privileged action'}: '
      'authorization was cancelled or denied',
    );
    addNotice(
      type: ManagerNoticeType.warning,
      title: t.text('alerts.authorizationDeniedTitle'),
      description: t.text('alerts.authorizationDeniedDescription'),
    );
  }

  void _publishPrivilegedFailure(String action, String detail) {
    addLog('[Error] $action: $detail');
    addNotice(
      type: ManagerNoticeType.error,
      title: t.text('alerts.privilegedActionFailedTitle'),
      description: t.text('alerts.privilegedActionFailedDescription', {
        'action': action,
        'error': detail,
      }),
    );
  }

  SystemSnapshot _mockSnapshot() => SystemSnapshot(
        collectedAt: DateTime.now().toUtc(),
        systemStatus: SystemStatus(
          deviceName: deviceName,
          ubuntuVersion: ubuntuVersion,
          secureBoot: secureBoot,
          lockdown: lockdown,
          luks: luks,
          tpmConfigured: tpmConfigured,
          hibernatePartition: hibernationCapacity,
          grubUpdated: grubConfigured,
          projectHeadersInstalled: headersInstalled,
        ),
        kernels: kernels,
        preflightDiagnostics: preflightDiagnostics,
        updater: updater,
        warnings: collectorWarnings,
      );

  @override
  void dispose() {
    _disposed = true;
    _cancelKernelCheckPoll();
    for (final timer in _noticeTimers.values) {
      timer.cancel();
    }
    _noticeTimers.clear();
    super.dispose();
  }
}

bool kernelReleaseMeetsMinimum(
  String release, {
  List<int> minimum = const [7, 0, 0],
}) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(release);
  if (match == null || minimum.length != 3) return false;
  final version = [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
  for (var index = 0; index < minimum.length; index++) {
    if (version[index] != minimum[index]) {
      return version[index] > minimum[index];
    }
  }
  return true;
}

class ManagerScope extends InheritedNotifier<ManagerController> {
  const ManagerScope({
    required ManagerController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ManagerController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ManagerScope>();
    assert(scope != null, 'ManagerScope is missing');
    return scope!.notifier!;
  }
}

extension ManagerContext on BuildContext {
  ManagerController get manager => ManagerScope.of(this);
  AppMessages get t => manager.t;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
