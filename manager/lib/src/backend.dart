import 'dart:typed_data';

enum BackendConnection { mock, loading, native, error }

enum KernelStatus { active, installed, available }

enum UpdatePolicy { manual, checkAndNotify, automaticInstall }

extension UpdatePolicyWireValue on UpdatePolicy {
  String get wireValue => switch (this) {
        UpdatePolicy.manual => 'manual',
        UpdatePolicy.checkAndNotify => 'check-and-notify',
        UpdatePolicy.automaticInstall => 'automatic-install',
      };

  static UpdatePolicy parse(String value) => switch (value) {
        'manual' => UpdatePolicy.manual,
        'check-and-notify' => UpdatePolicy.checkAndNotify,
        'automatic-install' => UpdatePolicy.automaticInstall,
        _ => throw FormatException('Unsupported update policy: $value'),
      };
}

enum ProjectMokStatus {
  unknown,
  pendingConfirmation,
  missing,
  pendingEnrollment,
  enrolled,
  cancelled,
  error,
}

enum InstallPhase {
  idle,
  preparing,
  indexingRelease,
  downloadingRelease,
  verifyingManifest,
  verifyingDownloadPackages,
  authorizingVersion,
  verifyingRelease,
  verifyingPackages,
  installingPackages,
  configuringSystem,
  complete,
  failed,
}

class InstallProgress {
  const InstallProgress({
    required this.phase,
    required this.progress,
    this.updatedAt,
  });

  const InstallProgress.idle()
      : phase = InstallPhase.idle,
        progress = 0,
        updatedAt = null;

  final InstallPhase phase;
  final int progress;
  final String? updatedAt;
}

bool installProgressBelongsToCurrentAction({
  required String? baselineUpdatedAt,
  required bool alreadyObserved,
  required InstallProgress observed,
}) =>
    alreadyObserved ||
    observed.updatedAt != null && observed.updatedAt != baselineUpdatedAt;

enum SetupCheckpoint { awaitingMokEnrollment, awaitingProjectKernelBoot }

extension SetupCheckpointWireValue on SetupCheckpoint {
  String get wireValue => switch (this) {
        SetupCheckpoint.awaitingMokEnrollment => 'awaiting-mok-enrollment',
        SetupCheckpoint.awaitingProjectKernelBoot =>
          'awaiting-project-kernel-boot',
      };

  static SetupCheckpoint parse(String value) => switch (value) {
        'awaiting-mok-enrollment' => SetupCheckpoint.awaitingMokEnrollment,
        'awaiting-project-kernel-boot' =>
          SetupCheckpoint.awaitingProjectKernelBoot,
        _ => throw FormatException('Unsupported setup checkpoint: $value'),
      };
}

class KernelInfo {
  const KernelInfo({
    required this.id,
    required this.version,
    required this.project,
    required this.status,
    this.releaseDate,
  });

  final String id;
  final String version;
  final bool project;
  final KernelStatus status;
  final String? releaseDate;

  bool get active => status == KernelStatus.active;
}

class SystemStatus {
  const SystemStatus({
    required this.deviceName,
    required this.ubuntuVersion,
    required this.secureBoot,
    required this.lockdown,
    required this.luks,
    required this.tpmConfigured,
    required this.hibernatePartition,
    required this.grubUpdated,
    required this.projectHeadersInstalled,
  });

  final String deviceName;
  final String ubuntuVersion;
  final bool secureBoot;
  final bool lockdown;
  final bool luks;
  final bool tpmConfigured;
  final bool hibernatePartition;
  final bool grubUpdated;
  final bool projectHeadersInstalled;
}

class PreflightDiagnostic {
  const PreflightDiagnostic({
    required this.id,
    required this.operation,
    required this.source,
    required this.arguments,
    required this.stdout,
    required this.stderr,
    required this.error,
    required this.exitCode,
  });

  final String id;
  final String operation;
  final String source;
  final List<String> arguments;
  final String stdout;
  final String stderr;
  final String? error;
  final int? exitCode;
}

class UpdateControllerStatus {
  const UpdateControllerStatus({
    required this.controllerInstalled,
    required this.policy,
    required this.lastCheckStatus,
    required this.lastCheckedAt,
    required this.availableSourceVersion,
    required this.availableKernelRelease,
    required this.installedSourceVersion,
    required this.installedKernelRelease,
    required this.rebootRequired,
    required this.timerEnabled,
    required this.timerActive,
    required this.nextCheckAt,
    required this.checkServiceActive,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.currentAsset,
    this.checkFailedPhase,
    this.lastCheckError,
    this.projectKernelHistory = 2,
  });

  const UpdateControllerStatus.empty()
      : controllerInstalled = false,
        policy = UpdatePolicy.manual,
        lastCheckStatus = null,
        lastCheckedAt = null,
        availableSourceVersion = null,
        availableKernelRelease = null,
        installedSourceVersion = null,
        installedKernelRelease = null,
        rebootRequired = false,
        timerEnabled = false,
        timerActive = false,
        nextCheckAt = null,
        checkServiceActive = false,
        downloadedBytes = null,
        totalBytes = null,
        currentAsset = null,
        checkFailedPhase = null,
        lastCheckError = null,
        projectKernelHistory = 2;

  final bool controllerInstalled;
  final UpdatePolicy policy;
  final String? lastCheckStatus;
  final String? lastCheckedAt;
  final String? availableSourceVersion;
  final String? availableKernelRelease;
  final String? installedSourceVersion;
  final String? installedKernelRelease;
  final bool rebootRequired;
  final bool timerEnabled;
  final bool timerActive;
  final String? nextCheckAt;
  final bool checkServiceActive;
  final int? downloadedBytes;
  final int? totalBytes;
  final String? currentAsset;
  final String? checkFailedPhase;
  final String? lastCheckError;
  final int projectKernelHistory;
}

class SystemSnapshot {
  const SystemSnapshot({
    required this.collectedAt,
    required this.systemStatus,
    required this.kernels,
    required this.preflightDiagnostics,
    required this.updater,
    required this.warnings,
  });

  final DateTime collectedAt;
  final SystemStatus systemStatus;
  final List<KernelInfo> kernels;
  final List<PreflightDiagnostic> preflightDiagnostics;
  final UpdateControllerStatus updater;
  final List<String> warnings;
}

enum ManagerActionType {
  startCheck,
  pauseCheck,
  resumeCheck,
  installUpdate,
  inspectMok,
  prepareMok,
  cancelMok,
  enrollTpm,
  verifyTpm,
  verifyRecovery,
  repairSwap,
  setPolicy,
  setKernelRetention,
  removeKernel,
}

extension ManagerActionWireValue on ManagerActionType {
  String get wireValue => switch (this) {
        ManagerActionType.startCheck => 'start-check',
        ManagerActionType.pauseCheck => 'pause-check',
        ManagerActionType.resumeCheck => 'resume-check',
        ManagerActionType.installUpdate => 'install-update',
        ManagerActionType.inspectMok => 'inspect-mok',
        ManagerActionType.prepareMok => 'prepare-mok',
        ManagerActionType.cancelMok => 'cancel-mok',
        ManagerActionType.enrollTpm => 'enroll-tpm',
        ManagerActionType.verifyTpm => 'verify-tpm',
        ManagerActionType.verifyRecovery => 'verify-recovery',
        ManagerActionType.repairSwap => 'repair-swap',
        ManagerActionType.setPolicy => 'set-policy',
        ManagerActionType.setKernelRetention => 'set-kernel-retention',
        ManagerActionType.removeKernel => 'remove-kernel',
      };
}

class ManagerActionRequest {
  const ManagerActionRequest(
    this.action, {
    this.policy,
    this.release,
    this.projectKernelHistory,
    this.recoveryPassword,
  });

  final ManagerActionType action;
  final UpdatePolicy? policy;
  final String? release;
  final int? projectKernelHistory;
  final Uint8List? recoveryPassword;
}

class ManagerTokenResult {
  const ManagerTokenResult({required this.tokenId, required this.passed});

  final String tokenId;
  final bool passed;
}

class ManagerActionData {
  const ManagerActionData({
    this.mokStatus,
    this.fingerprintSha256,
    this.oneTimePassword,
    this.policy,
    this.projectKernelHistory,
    this.removedRelease,
    this.removedPackages = const [],
    this.installedSourceVersion,
    this.installedKernelRelease,
    this.addedTokenIds = const [],
    this.headerBackup,
    this.crypttabChanged,
    this.alreadyConfigured,
    this.tokens = const [],
    this.passwordRecovery,
    this.swapPath,
    this.swapSizeBytes,
  });

  final String? mokStatus;
  final String? fingerprintSha256;
  final String? oneTimePassword;
  final UpdatePolicy? policy;
  final int? projectKernelHistory;
  final String? removedRelease;
  final List<String> removedPackages;
  final String? installedSourceVersion;
  final String? installedKernelRelease;
  final List<String> addedTokenIds;
  final String? headerBackup;
  final bool? crypttabChanged;
  final bool? alreadyConfigured;
  final List<ManagerTokenResult> tokens;
  final String? passwordRecovery;
  final String? swapPath;
  final int? swapSizeBytes;
}

enum ManagerActionStatus { success, cancelled, error }

class ManagerActionResult {
  const ManagerActionResult({
    required this.action,
    required this.status,
    required this.error,
    required this.data,
  });

  final ManagerActionType action;
  final ManagerActionStatus status;
  final String? error;
  final ManagerActionData data;
}

class ProjectMokInspection {
  const ProjectMokInspection({
    required this.status,
    required this.fingerprintSha256,
    required this.error,
    required this.oneTimePassword,
  });

  const ProjectMokInspection.unknown()
      : status = ProjectMokStatus.unknown,
        fingerprintSha256 = null,
        error = null,
        oneTimePassword = null;

  final ProjectMokStatus status;
  final String? fingerprintSha256;
  final String? error;
  final String? oneTimePassword;
}

class SetupProgress {
  const SetupProgress({required this.checkpoint, required this.completed});

  final SetupCheckpoint? checkpoint;
  final bool completed;
}

enum SystemActionStatus { started, cancelled, error }

class SystemActionResult {
  const SystemActionResult({required this.status, required this.error});

  final SystemActionStatus status;
  final String? error;
}

enum ExportStatus { saved, cancelled, error }

class ExportResult {
  const ExportResult({required this.status, required this.path, this.error});

  final ExportStatus status;
  final String? path;
  final String? error;
}

abstract interface class ManagerBackend {
  Future<SystemSnapshot> getSnapshot();
  Future<InstallProgress> getInstallProgress();
  Future<ProjectMokInspection> inspectProjectMok();
  Future<ManagerActionResult> runManagerAction(ManagerActionRequest request);
  Future<SetupProgress> getSetupProgress();
  Future<SetupProgress> clearSetupCheckpoint();
  Future<SetupProgress> completeSetup(bool requireTpm);
  Future<SetupProgress> saveSetupCheckpoint(SetupCheckpoint checkpoint);
  Future<SystemActionResult> restartForSetup(SetupCheckpoint checkpoint);
  Future<ExportResult> exportDiagnostics();
}
