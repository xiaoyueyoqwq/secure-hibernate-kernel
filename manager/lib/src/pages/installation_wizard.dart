import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../backend.dart';
import '../theme.dart';
import '../widgets/app_select.dart';
import '../widgets/core.dart';

enum DownloadPhase {
  idle,
  indexing,
  downloading,
  paused,
  verifyingManifest,
  verifyingPackages,
  authorizingVersion,
  complete,
  current,
  rebootRequired,
  packageManagerBusy,
  installFailed,
  releaseUnavailable,
  downgradeRefused,
  failed,
  unknown,
}

enum InstallationInspection { idle, checking, incomplete, complete, error }

DownloadPhase downloadPhaseForUpdaterStatus(
  String? status, {
  required bool checkServiceActive,
}) {
  const runningStatuses = {
    'indexing',
    'downloading',
    'verifying-manifest',
    'verifying-packages',
    'authorizing-version',
  };
  if (!checkServiceActive && runningStatuses.contains(status)) {
    return DownloadPhase.failed;
  }
  if (checkServiceActive &&
      {
        null,
        'manual',
        'paused',
        'current',
        'installed-reboot-required',
        'package-manager-busy',
        'install-failed',
        'release-unavailable',
        'downgrade-refused',
        'check-failed',
      }.contains(status)) {
    return DownloadPhase.indexing;
  }
  return switch (status) {
    'indexing' => DownloadPhase.indexing,
    'downloading' => DownloadPhase.downloading,
    'paused' => DownloadPhase.paused,
    'verifying-manifest' => DownloadPhase.verifyingManifest,
    'verifying-packages' => DownloadPhase.verifyingPackages,
    'authorizing-version' => DownloadPhase.authorizingVersion,
    'verified' ||
    'already-staged' ||
    'update-available' =>
      DownloadPhase.complete,
    'current' => DownloadPhase.current,
    'installed-reboot-required' => DownloadPhase.rebootRequired,
    'package-manager-busy' => DownloadPhase.packageManagerBusy,
    'install-failed' => DownloadPhase.installFailed,
    'release-unavailable' => DownloadPhase.releaseUnavailable,
    'downgrade-refused' => DownloadPhase.downgradeRefused,
    'check-failed' => DownloadPhase.failed,
    'manual' || null => DownloadPhase.idle,
    _ when checkServiceActive => DownloadPhase.indexing,
    _ => DownloadPhase.unknown,
  };
}

bool wizardStepIsSelectable({
  required bool debugMode,
  required int requestedStep,
  required int furthestStep,
}) =>
    debugMode || requestedStep <= furthestStep;

int checkFailureRowIndex(String? phase) => switch (phase) {
      'downloading' => 1,
      'verifying-manifest' => 2,
      'verifying-packages' => 3,
      'authorizing-version' => 4,
      _ => 0,
    };

bool installProgressTargetsProjectKernel(InstallPhase phase) => switch (phase) {
      InstallPhase.preparing ||
      InstallPhase.indexingRelease ||
      InstallPhase.downloadingRelease ||
      InstallPhase.verifyingManifest ||
      InstallPhase.verifyingDownloadPackages ||
      InstallPhase.authorizingVersion ||
      InstallPhase.verifyingRelease ||
      InstallPhase.verifyingPackages ||
      InstallPhase.installingPackages =>
        true,
      _ => false,
    };

bool installProgressTargetsSystemConfiguration(InstallPhase phase) =>
    phase == InstallPhase.configuringSystem;

bool installFailureTargetsSystemConfiguration(InstallProgress progress) =>
    progress.phase == InstallPhase.failed && progress.progress >= 90;

enum TpmInspection { unchecked, configured, needsConfiguration }

class InstallationWizardPage extends StatefulWidget {
  const InstallationWizardPage({super.key});

  @override
  State<InstallationWizardPage> createState() => _InstallationWizardPageState();
}

class _InstallationWizardPageState extends State<InstallationWizardPage> {
  static const nativeCheckStartPollLimit = 20;
  static const stepIcons = [
    LucideIcons.monitorCheck,
    LucideIcons.slidersHorizontal,
    LucideIcons.fileCheck2,
    LucideIcons.keyRound,
    LucideIcons.packageCheck,
    LucideIcons.refreshCw,
    LucideIcons.cpu,
  ];

  bool processing = false;
  bool installationComplete = false;
  bool packagesInstalled = false;
  InstallationInspection installationInspection = InstallationInspection.idle;
  bool bootVerified = false;
  TpmInspection tpmInspection = TpmInspection.unchecked;
  bool recoveryVerified = false;
  bool restartConfirmation = false;
  bool nativeSnapshotInitialized = false;
  bool resumedMokInspectionStarted = false;
  bool refreshingProgress = false;
  bool refreshingInstallProgress = false;
  DownloadPhase downloadPhase = DownloadPhase.idle;
  int downloadProgress = 0;
  InstallProgress installProgress = const InstallProgress.idle();
  Timer? phaseTimer;
  Timer? progressTimer;
  Timer? installProgressTimer;
  String? installProgressBaselineUpdatedAt;
  bool installActionProgressObserved = false;
  ({String? status, String? checkedAt})? nativeCheckStartBaseline;
  int nativeCheckStartPollsRemaining = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = context.manager;
    if (manager.native &&
        manager.snapshotLoaded &&
        !nativeSnapshotInitialized) {
      nativeSnapshotInitialized = true;
      syncNativeState();
      if (manager.currentWizardStep == 2 && _nativeTransferActive) {
        startNativeProgressPolling();
      }
    }
    if (manager.native &&
        manager.snapshotLoaded &&
        manager.setupCheckpoint == SetupCheckpoint.awaitingMokEnrollment &&
        manager.currentWizardStep == 3 &&
        !resumedMokInspectionStarted) {
      resumedMokInspectionStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(inspectResumedMokState());
      });
    }
  }

  Future<void> inspectResumedMokState() async {
    final manager = context.manager;
    setState(() => processing = true);
    try {
      final inspection = await manager.inspectProjectMok();
      if (inspection.status == ProjectMokStatus.pendingEnrollment &&
          inspection.oneTimePassword != null) {
        await manager.saveSetupCheckpoint(
          SetupCheckpoint.awaitingMokEnrollment,
        );
      }
    } on Object catch (error) {
      publishWizardError(error);
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  @override
  void dispose() {
    phaseTimer?.cancel();
    progressTimer?.cancel();
    installProgressTimer?.cancel();
    super.dispose();
  }

  void selectStep(int step) {
    final manager = context.manager;
    phaseTimer?.cancel();
    progressTimer?.cancel();
    installProgressTimer?.cancel();
    nativeCheckStartBaseline = null;
    nativeCheckStartPollsRemaining = 0;
    restartConfirmation = false;
    manager.selectWizardStep(step);
    if (manager.native && step == 2) {
      unawaited(refreshNativeProgress());
    }
    if (manager.native && step == 4) {
      unawaited(inspectInstallationState());
    } else if (!manager.native && step == 4) {
      installationInspection = packagesInstalled
          ? InstallationInspection.complete
          : InstallationInspection.incomplete;
    }
  }

  void selectTimelineStep(int step) {
    final manager = context.manager;
    if (!wizardStepIsSelectable(
      debugMode: kDebugMode,
      requestedStep: step,
      furthestStep: manager.furthestWizardStep,
    )) {
      return;
    }
    selectStep(step);
  }

  Future<void> process(Duration duration, VoidCallback complete) async {
    if (processing) return;
    setState(() => processing = true);
    await Future<void>.delayed(duration);
    if (!mounted) return;
    setState(() => processing = false);
    complete();
  }

  void publishWizardError(Object error) {
    if (!mounted) return;
    final manager = context.manager;
    final detail = error.toString();
    if (manager.notices.any(
      (notice) =>
          notice.type == ManagerNoticeType.error &&
          notice.description == detail,
    )) {
      return;
    }
    manager.addLog('[Error] installation wizard: $detail');
    manager.addNotice(
      type: ManagerNoticeType.error,
      title: context.t.text('alerts.privilegedActionFailedTitle'),
      description: detail,
    );
  }

  Future<void> startDownload() async {
    final manager = context.manager;
    if (manager.native) {
      final action = downloadPhase == DownloadPhase.downloading
          ? ManagerActionType.pauseCheck
          : downloadPhase == DownloadPhase.paused
              ? ManagerActionType.resumeCheck
              : ManagerActionType.startCheck;
      final startsCheck = action == ManagerActionType.startCheck ||
          action == ManagerActionType.resumeCheck;
      final previousStatus = manager.updater.lastCheckStatus;
      final previousCheckedAt = manager.updater.lastCheckedAt;
      setState(() => processing = true);
      final result = action == ManagerActionType.startCheck
          ? await manager.startKernelUpdateCheck()
          : await manager.runManagerAction(ManagerActionRequest(action));
      if (!mounted) return;
      if (result.status == ManagerActionStatus.success && startsCheck) {
        setState(() {
          nativeCheckStartBaseline = (
            status: previousStatus,
            checkedAt: previousCheckedAt,
          );
          nativeCheckStartPollsRemaining = nativeCheckStartPollLimit;
          downloadPhase = DownloadPhase.indexing;
          downloadProgress = 0;
        });
      }
      try {
        await manager.refreshSnapshot();
        syncNativeState();
        if (_nativeTransferActive) startNativeProgressPolling();
      } on Object catch (error) {
        publishWizardError(error);
        if (_nativeTransferActive) startNativeProgressPolling();
      }
      if (!mounted) return;
      setState(() => processing = false);
      return;
    }
    if (downloadPhase == DownloadPhase.downloading) {
      progressTimer?.cancel();
      setState(() => downloadPhase = DownloadPhase.paused);
      context.manager.addLog('[Download] Paused at $downloadProgress%');
      return;
    }
    if (downloadPhase == DownloadPhase.paused) {
      setState(() => downloadPhase = DownloadPhase.downloading);
      context.manager.addLog('[Download] Resuming from $downloadProgress%');
      runTransfer();
      return;
    }
    if (downloadPhase != DownloadPhase.idle) return;
    setState(() {
      downloadProgress = 0;
      downloadPhase = DownloadPhase.indexing;
    });
    context.manager
        .addLog('[Download] Indexing the latest project Release URLs');
    phaseTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => downloadPhase = DownloadPhase.downloading);
      context.manager
          .addLog('[Download] Release URLs indexed; package transfer started');
      runTransfer();
    });
  }

  bool get _nativeTransferActive => switch (downloadPhase) {
        DownloadPhase.indexing ||
        DownloadPhase.downloading ||
        DownloadPhase.verifyingManifest ||
        DownloadPhase.verifyingPackages ||
        DownloadPhase.authorizingVersion =>
          true,
        _ => false,
      };

  void startNativeProgressPolling() {
    progressTimer?.cancel();
    if (context.manager.currentWizardStep != 2) return;
    progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(refreshNativeProgress());
    });
  }

  Future<void> refreshNativeProgress() async {
    if (!mounted || refreshingProgress || !context.manager.native) return;
    if (context.manager.currentWizardStep != 2) {
      progressTimer?.cancel();
      return;
    }
    refreshingProgress = true;
    try {
      await context.manager.refreshSnapshot();
      if (!mounted) return;
      setState(syncNativeState);
      if (!_nativeTransferActive) progressTimer?.cancel();
    } on Object catch (error) {
      progressTimer?.cancel();
      publishWizardError(error);
    } finally {
      refreshingProgress = false;
    }
  }

  void startInstallProgressPolling() {
    installProgressTimer?.cancel();
    installProgressTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) {
      unawaited(refreshInstallProgress());
    });
  }

  Future<void> refreshInstallProgress() async {
    if (!mounted || refreshingInstallProgress || !context.manager.native) {
      return;
    }
    refreshingInstallProgress = true;
    try {
      final observed = await context.manager.getInstallProgress();
      final belongsToCurrentAction = installProgressBelongsToCurrentAction(
        baselineUpdatedAt: installProgressBaselineUpdatedAt,
        alreadyObserved: installActionProgressObserved,
        observed: observed,
      );
      if (mounted && belongsToCurrentAction) {
        setState(() {
          installActionProgressObserved = true;
          installProgress = observed;
        });
      }
    } on Object catch (error) {
      installProgressTimer?.cancel();
      publishWizardError(error);
    } finally {
      refreshingInstallProgress = false;
    }
  }

  bool get installProgressActive => switch (installProgress.phase) {
        InstallPhase.preparing ||
        InstallPhase.indexingRelease ||
        InstallPhase.downloadingRelease ||
        InstallPhase.verifyingManifest ||
        InstallPhase.verifyingDownloadPackages ||
        InstallPhase.authorizingVersion ||
        InstallPhase.verifyingRelease ||
        InstallPhase.verifyingPackages ||
        InstallPhase.installingPackages ||
        InstallPhase.configuringSystem =>
          true,
        _ => false,
      };

  void syncNativeState() {
    final manager = context.manager;
    final observedPhase = downloadPhaseForUpdaterStatus(
      manager.updater.lastCheckStatus,
      checkServiceActive: manager.updater.checkServiceActive,
    );
    final baseline = nativeCheckStartBaseline;
    final checkStateAdvanced = baseline != null &&
        (manager.updater.lastCheckStatus != baseline.status ||
            manager.updater.lastCheckedAt != baseline.checkedAt);
    if (baseline != null &&
        !checkStateAdvanced &&
        (manager.updater.checkServiceActive ||
            nativeCheckStartPollsRemaining > 0)) {
      if (!manager.updater.checkServiceActive) {
        nativeCheckStartPollsRemaining -= 1;
      }
      downloadPhase = DownloadPhase.indexing;
    } else {
      nativeCheckStartBaseline = null;
      nativeCheckStartPollsRemaining = 0;
      downloadPhase = observedPhase;
    }
    final downloaded = manager.updater.downloadedBytes;
    final total = manager.updater.totalBytes;
    downloadProgress = downloaded != null && total != null && total > 0
        ? ((downloaded * 100) / total).round().clamp(0, 100)
        : downloadPhase == DownloadPhase.complete ||
                downloadPhase == DownloadPhase.current ||
                downloadPhase == DownloadPhase.rebootRequired ||
                downloadPhase == DownloadPhase.packageManagerBusy ||
                downloadPhase == DownloadPhase.installFailed ||
                downloadPhase == DownloadPhase.downgradeRefused
            ? 100
            : 0;
    packagesInstalled = _installationReady(manager);
    bootVerified = _bootEnvironmentReady(manager);
  }

  bool _installationReady(ManagerController manager) {
    return _projectKernelReady(manager) &&
        manager.headersInstalled &&
        manager.grubConfigured &&
        manager.updater.controllerInstalled;
  }

  bool _projectKernelReady(ManagerController manager) {
    final target = _installationTarget(manager);
    return target != null &&
        manager.kernels.any((kernel) =>
            kernel.project &&
            kernel.status != KernelStatus.available &&
            kernel.version == target);
  }

  String? _installationTarget(ManagerController manager) =>
      switch (downloadPhase) {
        DownloadPhase.current ||
        DownloadPhase.rebootRequired ||
        DownloadPhase.downgradeRefused =>
          manager.updater.installedKernelRelease,
        _ => manager.updater.availableKernelRelease ??
            manager.updater.installedKernelRelease,
      };

  bool _downloadCanContinue(ManagerController manager) =>
      switch (downloadPhase) {
        DownloadPhase.complete ||
        DownloadPhase.packageManagerBusy ||
        DownloadPhase.installFailed =>
          manager.updater.availableSourceVersion != null &&
              manager.updater.availableKernelRelease != null,
        DownloadPhase.current ||
        DownloadPhase.rebootRequired ||
        DownloadPhase.downgradeRefused =>
          _projectKernelReady(manager) && manager.headersInstalled,
        _ => false,
      };

  bool _bootEnvironmentReady(ManagerController manager) {
    final target = manager.updater.installedKernelRelease;
    return target != null &&
        manager.activeKernel.project &&
        manager.activeKernel.version == target &&
        manager.secureBoot &&
        manager.lockdown &&
        manager.officialFallbackInstalled;
  }

  bool _bootEnvironmentFailed(ManagerController manager) {
    return !manager.secureBoot ||
        !manager.lockdown ||
        !manager.officialFallbackInstalled ||
        manager.updater.installedKernelRelease == null;
  }

  Future<bool> inspectInstallationState() async {
    final manager = context.manager;
    if (!manager.native) return packagesInstalled;
    setState(() {
      processing = true;
      installationInspection = InstallationInspection.checking;
    });
    try {
      await manager.refreshSnapshot();
      final complete = _installationReady(manager);
      if (mounted) {
        setState(() {
          packagesInstalled = complete;
          installationInspection = complete
              ? InstallationInspection.complete
              : InstallationInspection.incomplete;
          bootVerified = _bootEnvironmentReady(manager);
        });
      }
      manager.addLog(complete
          ? '[Installation] Existing installation and configuration verified'
          : '[Installation] Installation or configuration is incomplete');
      return complete;
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => installationInspection = InstallationInspection.error,
        );
      }
      publishWizardError(error);
      return false;
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  void runTransfer() {
    progressTimer?.cancel();
    progressTimer = Timer.periodic(const Duration(milliseconds: 140), (timer) {
      if (!mounted || downloadPhase != DownloadPhase.downloading) {
        timer.cancel();
        return;
      }
      setState(() {
        final increment = downloadProgress < 25
            ? 3
            : downloadProgress < 70
                ? 2
                : 1;
        downloadProgress = (downloadProgress + increment).clamp(0, 100);
      });
      if (downloadProgress == 100) {
        timer.cancel();
        advanceDownloadVerification(DownloadPhase.verifyingManifest);
      }
    });
  }

  void advanceDownloadVerification(DownloadPhase phase) {
    if (!mounted) return;
    setState(() => downloadPhase = phase);
    final (next, delay) = switch (phase) {
      DownloadPhase.verifyingManifest => (DownloadPhase.verifyingPackages, 800),
      DownloadPhase.verifyingPackages => (
          DownloadPhase.authorizingVersion,
          1100
        ),
      DownloadPhase.authorizingVersion => (DownloadPhase.complete, 700),
      _ => (DownloadPhase.complete, 500),
    };
    phaseTimer = Timer(Duration(milliseconds: delay), () {
      if (!mounted) return;
      if (next == DownloadPhase.complete) {
        setState(() => downloadPhase = DownloadPhase.complete);
        context.manager
            .addLog('[Download] Release download and verification completed');
        phaseTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) selectStep(3);
        });
      } else {
        advanceDownloadVerification(next);
      }
    });
  }

  bool get preflightFailed {
    final manager = context.manager;
    return !manager.runningKernelSupported ||
        !manager.secureBoot ||
        !manager.lockdown ||
        !manager.hibernationCapacity ||
        !manager.officialFallbackInstalled;
  }

  Future<void> handleAction() async {
    final manager = context.manager;
    final step = manager.currentWizardStep;
    switch (step) {
      case 0:
        if (manager.native) {
          setState(() => processing = true);
          try {
            await manager.refreshSnapshot();
          } on Object catch (error) {
            publishWizardError(error);
          }
          if (!mounted) return;
          setState(() => processing = false);
        }
        if (manager.native && !manager.hibernationCapacity) {
          setState(() => processing = true);
          final result = await manager.runManagerAction(
            const ManagerActionRequest(ManagerActionType.repairSwap),
          );
          if (result.status == ManagerActionStatus.success) {
            try {
              await manager.refreshSnapshot();
            } on Object catch (error) {
              publishWizardError(error);
            }
          }
          if (!mounted) return;
          setState(() => processing = false);
          return;
        }
        if (preflightFailed) return;
        selectStep(1);
      case 1:
        if (manager.native) {
          setState(() => processing = true);
          final result = await manager.changeUpdatePolicy(manager.updatePolicy);
          if (!mounted) return;
          setState(() => processing = false);
          if (result?.status == ManagerActionStatus.success) {
            selectStep(2);
          }
        } else {
          await process(const Duration(milliseconds: 700), () => selectStep(2));
        }
      case 2:
        if (_downloadCanContinue(manager)) {
          selectStep(3);
        } else {
          await startDownload();
        }
      case 3:
        if (manager.native) {
          if (manager.projectMokStatus == ProjectMokStatus.pendingEnrollment) {
            if (usesLegacyMokPassword(manager.mokOneTimePassword)) {
              setState(() => processing = true);
              final result = await manager.runManagerAction(
                const ManagerActionRequest(ManagerActionType.prepareMok),
              );
              if (result.status == ManagerActionStatus.success &&
                  result.data.mokStatus == 'pending' &&
                  result.data.oneTimePassword != null) {
                await manager.saveSetupCheckpoint(
                  SetupCheckpoint.awaitingMokEnrollment,
                );
              }
              if (!mounted) return;
              setState(() => processing = false);
              return;
            }
            if (!restartConfirmation) {
              setState(() => restartConfirmation = true);
              return;
            }
            setState(() => processing = true);
            await manager.restartForSetup(
              SetupCheckpoint.awaitingMokEnrollment,
            );
            if (!mounted) return;
            setState(() {
              processing = false;
              restartConfirmation = false;
            });
            return;
          }
          if (manager.projectMokStatus == ProjectMokStatus.enrolled) {
            await manager.clearSetupCheckpoint();
            selectStep(4);
            return;
          }
          if (manager.projectMokStatus == ProjectMokStatus.missing) {
            setState(() => processing = true);
            final result = await manager.runManagerAction(
              const ManagerActionRequest(ManagerActionType.prepareMok),
            );
            if (result.status == ManagerActionStatus.success &&
                result.data.mokStatus == 'pending' &&
                result.data.oneTimePassword != null) {
              await manager.saveSetupCheckpoint(
                SetupCheckpoint.awaitingMokEnrollment,
              );
            }
            if (!mounted) return;
            setState(() => processing = false);
            return;
          }
          setState(() => processing = true);
          final inspection = await manager.inspectProjectMok();
          if (inspection.status == ProjectMokStatus.pendingEnrollment &&
              inspection.oneTimePassword != null) {
            await manager.saveSetupCheckpoint(
              SetupCheckpoint.awaitingMokEnrollment,
            );
          }
          if (!mounted) return;
          setState(() => processing = false);
          return;
        }
        if (manager.projectMokStatus == ProjectMokStatus.unknown) {
          await process(const Duration(milliseconds: 700), () {
            manager.projectMokStatus = ProjectMokStatus.missing;
            manager.addLog('[System] Project MOK inspection result: missing');
          });
        } else if (manager.projectMokStatus == ProjectMokStatus.missing) {
          await process(const Duration(milliseconds: 800), () {
            manager.projectMokStatus = ProjectMokStatus.pendingEnrollment;
            manager.addLog('[System] Project MOK enrollment prepared');
          });
        } else if (manager.projectMokStatus ==
            ProjectMokStatus.pendingEnrollment) {
          if (!restartConfirmation) {
            setState(() => restartConfirmation = true);
          } else {
            await process(const Duration(milliseconds: 900), () {
              manager.projectMokStatus = ProjectMokStatus.enrolled;
              restartConfirmation = false;
              selectStep(4);
            });
          }
        } else {
          selectStep(4);
        }
      case 4:
        if (manager.native) {
          if (installationInspection == InstallationInspection.idle ||
              installationInspection == InstallationInspection.checking) {
            return;
          }
          if (installationInspection == InstallationInspection.error) {
            await inspectInstallationState();
            return;
          }
          if (installationInspection == InstallationInspection.complete) {
            selectStep(5);
            return;
          }
          setState(() {
            processing = true;
            installProgress = const InstallProgress.idle();
            installActionProgressObserved = false;
          });
          final baseline = await manager.getInstallProgress();
          installProgressBaselineUpdatedAt = baseline.updatedAt;
          startInstallProgressPolling();
          final result = await manager.runManagerAction(
            const ManagerActionRequest(ManagerActionType.installUpdate),
          );
          installProgressTimer?.cancel();
          final completedProgress = await manager.getInstallProgress();
          if (completedProgress.updatedAt != installProgressBaselineUpdatedAt) {
            installActionProgressObserved = true;
            installProgress = completedProgress;
          }
          if (result.status == ManagerActionStatus.success) {
            final complete = await inspectInstallationState();
            if (complete) {
              await manager.saveSetupCheckpoint(
                SetupCheckpoint.awaitingProjectKernelBoot,
              );
              selectStep(5);
            }
          } else if (result.status == ManagerActionStatus.error) {
            installationInspection = InstallationInspection.error;
          }
          if (!mounted) return;
          setState(() => processing = false);
          return;
        }
        if (!packagesInstalled) {
          await process(const Duration(milliseconds: 1800), () {
            packagesInstalled = true;
            manager.addLog(
              '[Installation] Project kernel, GRUB integration, and update controller installed',
            );
            selectStep(5);
          });
        } else {
          selectStep(5);
        }
      case 5:
        if (manager.native) {
          await manager.refreshSnapshot();
          bootVerified = _bootEnvironmentReady(manager);
          if (bootVerified) {
            await manager.clearSetupCheckpoint();
            if (mounted) selectStep(6);
            return;
          }
          if (_bootEnvironmentFailed(manager)) {
            if (mounted) await showPreflightDialog(context);
            return;
          }
          if (!restartConfirmation) {
            setState(() => restartConfirmation = true);
            return;
          }
          setState(() => processing = true);
          await manager.restartForSetup(
            SetupCheckpoint.awaitingProjectKernelBoot,
          );
          if (!mounted) return;
          setState(() {
            processing = false;
            restartConfirmation = false;
          });
          return;
        }
        if (bootVerified) {
          selectStep(6);
        } else if (!restartConfirmation) {
          setState(() => restartConfirmation = true);
        } else {
          await process(const Duration(milliseconds: 1000), () {
            bootVerified = true;
            restartConfirmation = false;
            manager.lockdown = true;
            selectStep(6);
          });
        }
      case 6:
        if (manager.native) {
          if (!manager.luks) {
            try {
              await manager.completeNativeSetup();
            } on Object catch (error) {
              publishWizardError(error);
            }
            return;
          }
          if (!installationComplete) {
            if (manager.configureTpm &&
                tpmInspection == TpmInspection.unchecked) {
              setState(() => processing = true);
              try {
                final result = await manager.runManagerAction(
                  const ManagerActionRequest(ManagerActionType.verifyTpm),
                );
                if (result.status == ManagerActionStatus.success && mounted) {
                  setState(() {
                    tpmInspection = result.data.alreadyConfigured == true
                        ? TpmInspection.configured
                        : TpmInspection.needsConfiguration;
                  });
                }
              } on Object catch (error) {
                publishWizardError(error);
              } finally {
                if (mounted) setState(() => processing = false);
              }
              return;
            }
            final action = manager.configureTpm &&
                    tpmInspection == TpmInspection.needsConfiguration
                ? ManagerActionType.enrollTpm
                : ManagerActionType.verifyRecovery;
            final recoveryPassword =
                await showLuksRecoveryPasswordDialog(context);
            if (recoveryPassword == null) return;
            if (!mounted) {
              recoveryPassword.fillRange(0, recoveryPassword.length, 0);
              return;
            }
            setState(() => processing = true);
            try {
              final result = await manager.runManagerAction(
                ManagerActionRequest(
                  action,
                  recoveryPassword: recoveryPassword,
                ),
              );
              if (result.status == ManagerActionStatus.success) {
                if (action == ManagerActionType.enrollTpm) {
                  tpmInspection = TpmInspection.configured;
                }
                recoveryVerified = result.data.passwordRecovery == 'verified';
                installationComplete = recoveryVerified &&
                    (!manager.configureTpm ||
                        tpmInspection == TpmInspection.configured);
                await manager.refreshSnapshot();
              }
            } on Object catch (error) {
              publishWizardError(error);
            } finally {
              recoveryPassword.fillRange(0, recoveryPassword.length, 0);
              if (mounted) setState(() => processing = false);
            }
            return;
          }
          if (!recoveryVerified ||
              (manager.configureTpm &&
                  tpmInspection != TpmInspection.configured)) {
            return;
          }
          try {
            await manager.completeNativeSetup();
          } on Object catch (error) {
            publishWizardError(error);
          }
          return;
        }
        if (!installationComplete) {
          await process(const Duration(milliseconds: 1200), () {
            tpmInspection = manager.configureTpm
                ? TpmInspection.configured
                : TpmInspection.unchecked;
            recoveryVerified = true;
            manager.tpmConfigured = manager.configureTpm;
            installationComplete = true;
            manager.addLog('[System] Setup verification completed');
          });
        } else {
          manager.advanceWizard();
        }
    }
  }

  String actionLabel() {
    final manager = context.manager;
    final t = context.t;
    return switch (manager.currentWizardStep) {
      0 => !manager.snapshotLoaded &&
              manager.backendConnection == BackendConnection.loading
          ? t.text('common.checkingStatus')
          : processing && !manager.hibernationCapacity
              ? t.text('common.fixingSwap')
              : manager.native && !manager.hibernationCapacity
                  ? t.text('common.fixAutomatically')
                  : manager.backendConnection == BackendConnection.error ||
                          preflightFailed
                      ? t.text('common.recheck')
                      : t.text('common.continue'),
      2 => switch (downloadPhase) {
          DownloadPhase.idle => t.text('common.startDownload'),
          DownloadPhase.indexing => t.text('common.indexingRelease'),
          DownloadPhase.downloading => '$downloadProgress%',
          DownloadPhase.paused =>
            '${t.text('common.paused')} · $downloadProgress%',
          DownloadPhase.complete ||
          DownloadPhase.current ||
          DownloadPhase.rebootRequired ||
          DownloadPhase.packageManagerBusy ||
          DownloadPhase.installFailed ||
          DownloadPhase.downgradeRefused =>
            _downloadCanContinue(manager)
                ? t.text('common.continue')
                : t.text('common.recheck'),
          DownloadPhase.releaseUnavailable ||
          DownloadPhase.failed ||
          DownloadPhase.unknown =>
            t.text('common.recheck'),
          _ => t.text('common.verifyingDownload'),
        },
      3 => manager.projectMokStatus == ProjectMokStatus.pendingConfirmation
          ? t.text('wizard.awaitingAuthorization')
          : manager.projectMokStatus == ProjectMokStatus.unknown ||
                  manager.projectMokStatus == ProjectMokStatus.error ||
                  manager.projectMokStatus == ProjectMokStatus.cancelled
              ? t.text('common.checkStatus')
              : manager.projectMokStatus == ProjectMokStatus.missing
                  ? t.text('common.prepareEnrollment')
                  : manager.projectMokStatus ==
                          ProjectMokStatus.pendingEnrollment
                      ? usesLegacyMokPassword(manager.mokOneTimePassword)
                          ? t.text('common.regeneratePassword')
                          : restartConfirmation
                              ? t.text('common.confirmRestart')
                              : t.text('common.restart')
                      : t.text('common.continue'),
      4 => switch (installationInspection) {
          _
              when processing &&
                  installActionProgressObserved &&
                  installProgressActive =>
            '${installProgress.progress}%',
          InstallationInspection.idle ||
          InstallationInspection.checking =>
            t.text('common.checkingStatus'),
          InstallationInspection.error => t.text('common.recheck'),
          InstallationInspection.complete => t.text('common.continue'),
          InstallationInspection.incomplete =>
            t.text('common.startInstallation'),
        },
      5 => bootVerified
          ? t.text('common.continue')
          : _bootEnvironmentFailed(manager)
              ? t.text('common.getHelp')
              : restartConfirmation
                  ? t.text('common.confirmRestart')
                  : t.text('common.restart'),
      6 => installationComplete
          ? t.text('common.finish')
          : !manager.luks
              ? t.text('common.finish')
              : manager.configureTpm
                  ? switch (tpmInspection) {
                      TpmInspection.unchecked => t.text('common.checkTpm'),
                      TpmInspection.needsConfiguration =>
                        t.text('common.configureTpm'),
                      TpmInspection.configured =>
                        t.text('common.verifyRecovery'),
                    }
                  : t.text('common.verifyRecovery'),
      _ => t.text('common.continue'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    final titles = t.list('wizard.stepTitles');
    final descriptions = t.list('wizard.stepDescriptions');
    final current = manager.currentWizardStep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: t.text('wizard.title'),
          description: t.text('wizard.description'),
        ),
        const SizedBox(height: 32),
        WizardTimeline(
          current: current,
          furthest: manager.furthestWizardStep,
          complete: installationComplete,
          labels: t.list('wizard.shortSteps'),
          icons: stepIcons,
          onSelected: processing ? null : selectTimelineStep,
        ),
        const SizedBox(height: 32),
        SectionTitle(t.text('wizard.currentStep')),
        const SizedBox(height: 16),
        if (current == 3 &&
            manager.projectMokStatus == ProjectMokStatus.pendingEnrollment &&
            !usesLegacyMokPassword(manager.mokOneTimePassword)) ...[
          WizardCallout(
            title: t.text('wizard.restartRequired'),
            description: t.text('wizard.restartDescription'),
          ),
          const SizedBox(height: 16),
        ],
        if (current == 5 && !bootVerified) ...[
          WizardCallout(
            title: t.text('wizard.bootRestartRequired'),
            description: t.text('wizard.bootRestartDescription'),
          ),
          const SizedBox(height: 16),
        ],
        AppCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final heading = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.text('wizard.stepOf', {
                          'current': current + 1,
                          'total': titles.length,
                        }),
                        style: TextStyle(
                          color: context.palette.textFaint,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        titles[current],
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        descriptions[current],
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  );
                  final action = DownloadActionButton(
                    label: actionLabel(),
                    busy: processing ||
                        manager.backendConnection ==
                            BackendConnection.loading ||
                        current == 2 &&
                            (downloadPhase == DownloadPhase.indexing ||
                                downloadPhase ==
                                    DownloadPhase.verifyingManifest ||
                                downloadPhase ==
                                    DownloadPhase.verifyingPackages ||
                                downloadPhase ==
                                    DownloadPhase.authorizingVersion),
                    transfer: current == 2 &&
                            (downloadPhase == DownloadPhase.downloading ||
                                downloadPhase == DownloadPhase.paused) ||
                        current == 4 &&
                            processing &&
                            installActionProgressObserved &&
                            installProgressActive,
                    progress: current == 4
                        ? installProgress.progress
                        : downloadProgress,
                    danger:
                        restartConfirmation && (current == 3 || current == 5),
                    tooltip: current == 2 &&
                            downloadPhase == DownloadPhase.downloading
                        ? t.text('common.pauseDownload')
                        : current == 2 && downloadPhase == DownloadPhase.paused
                            ? t.text('common.resumeDownload')
                            : null,
                    onPressed: handleAction,
                  );
                  if (constraints.maxWidth < 620) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [heading, const SizedBox(height: 20), action],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: heading),
                      const SizedBox(width: 20),
                      action,
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              Divider(height: 1, thickness: 1, color: context.palette.border),
              const SizedBox(height: 8),
              WizardStepDetails(
                step: current,
                downloadPhase: downloadPhase,
                downloadProgress: downloadProgress,
                installationInspection: installationInspection,
                installProgress: installProgress,
                installActionProgressObserved: installActionProgressObserved,
                processing: processing,
                bootVerified: bootVerified,
                tpmInspection: tpmInspection,
                recoveryVerified: recoveryVerified,
              ),
              if (installationComplete) ...[
                const SizedBox(height: 12),
                Text(
                  t.text('wizard.completedDescription'),
                  style: const TextStyle(
                    color: Color(0xff047857),
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class WizardTimeline extends StatelessWidget {
  const WizardTimeline({
    required this.current,
    required this.furthest,
    required this.complete,
    required this.labels,
    required this.icons,
    required this.onSelected,
    super.key,
  });

  final int current;
  final int furthest;
  final bool complete;
  final List<String> labels;
  final List<IconData> icons;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = MediaQuery.sizeOf(context).width;
          final width = (viewportWidth - 100).clamp(672.0, 896.0);
          final cell = width / 7;
          return SizedBox(
            width: width,
            height: 58,
            child: Stack(
              children: [
                Positioned(
                  left: cell / 2,
                  right: cell / 2,
                  top: 15,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: context.palette.dark ? Neutral.n700 : Neutral.n200,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    alignment: Alignment.centerLeft,
                    child: AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      widthFactor: furthest / 6,
                      child: Container(
                        decoration: BoxDecoration(
                          color: context.palette.activeFill,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: List.generate(7, (index) {
                    final completed = (index < furthest && index != current) ||
                        (index == 6 && complete);
                    final active = index == current && !completed;
                    return SizedBox(
                      width: cell,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onSelected == null
                            ? null
                            : () => onSelected!(index),
                        child: Column(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: completed || active
                                    ? context.palette.activeFill
                                    : context.palette.contentBackground,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: completed || active
                                      ? context.palette.activeFill
                                      : context.palette.dark
                                          ? Neutral.n600
                                          : Neutral.n300,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                completed ? LucideIcons.check : icons[index],
                                size: 14,
                                color: completed || active
                                    ? context.palette.activeText
                                    : context.palette.textMuted,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              labels[index],
                              maxLines: 1,
                              overflow: TextOverflow.visible,
                              style: TextStyle(
                                color: active
                                    ? context.palette.textStrong
                                    : completed
                                        ? context.palette.textMedium
                                        : context.palette.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class WizardCallout extends StatelessWidget {
  const WizardCallout({
    required this.title,
    required this.description,
    super.key,
  });

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final dark = context.palette.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xff451a03).withValues(alpha: 0.40)
            : const Color(0xfffffbeb),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: dark ? const Color(0xff92400e) : const Color(0xfffcd34d),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: dark ? const Color(0xfffcd34d) : const Color(0xff78350f),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(
              color: dark ? const Color(0xfffcd34d) : const Color(0xff78350f),
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadActionButton extends StatelessWidget {
  const DownloadActionButton({
    required this.label,
    required this.busy,
    required this.transfer,
    required this.progress,
    required this.danger,
    required this.onPressed,
    this.tooltip,
    super.key,
  });

  final String label;
  final bool busy;
  final bool transfer;
  final int progress;
  final bool danger;
  final String? tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget content(Color color) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy && !transfer) ...[
                SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
    final button = GestureDetector(
      onTap: busy ? null : onPressed,
      child: Opacity(
        opacity: busy && !transfer ? 0.65 : 1,
        child: Container(
          width: 144,
          height: 36,
          decoration: BoxDecoration(
            color: danger
                ? const Color(0xffb91c1c)
                : transfer
                    ? palette.card
                    : palette.activeFill,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: danger
                  ? const Color(0xffb91c1c)
                  : transfer
                      ? palette.activeFill
                      : Colors.transparent,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              if (transfer)
                AnimatedFractionallySizedBox(
                  key: const ValueKey('wizard-action-transfer-fill'),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.centerLeft,
                  widthFactor: progress / 100,
                  heightFactor: 1,
                  child: ColoredBox(color: palette.activeFill),
                ),
              if (transfer) ...[
                Positioned.fill(child: content(palette.text)),
                Positioned.fill(
                  child: AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    alignment: Alignment.centerLeft,
                    widthFactor: progress / 100,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: 142,
                        maxWidth: 142,
                        child: SizedBox(
                          width: 142,
                          height: 34,
                          child: content(palette.activeText),
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                Positioned.fill(
                  child: content(danger ? Colors.white : palette.activeText),
                ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class WizardStepDetails extends StatelessWidget {
  const WizardStepDetails({
    required this.step,
    required this.downloadPhase,
    required this.downloadProgress,
    required this.installationInspection,
    required this.installProgress,
    required this.installActionProgressObserved,
    required this.processing,
    required this.bootVerified,
    required this.tpmInspection,
    required this.recoveryVerified,
    super.key,
  });

  final int step;
  final DownloadPhase downloadPhase;
  final int downloadProgress;
  final InstallationInspection installationInspection;
  final InstallProgress installProgress;
  final bool installActionProgressObserved;
  final bool processing;
  final bool bootVerified;
  final TpmInspection tpmInspection;
  final bool recoveryVerified;

  List<DetailRow> _installationRows({
    required ManagerController manager,
    required String? installationTarget,
    required String Function(String) details,
  }) {
    if (installationInspection == InstallationInspection.idle ||
        installationInspection == InstallationInspection.checking) {
      return [
        for (final label in [
          details('projectKernel'),
          details('grubIntegration'),
          details('updateController'),
        ])
          DetailRow(
            label: label,
            value: details('checking'),
            status: StatusKind.loading,
          ),
      ];
    }

    final projectKernelInstalled = installationTarget != null &&
        manager.headersInstalled &&
        manager.kernels.any((kernel) =>
            kernel.project &&
            kernel.status != KernelStatus.available &&
            kernel.version == installationTarget);
    final progressVisible = installActionProgressObserved &&
        (installProgressTargetsProjectKernel(installProgress.phase) ||
            installProgressTargetsSystemConfiguration(installProgress.phase) ||
            installProgress.phase == InstallPhase.failed);
    if (progressVisible) {
      final projectKernelActive =
          installProgressTargetsProjectKernel(installProgress.phase);
      final systemConfigurationActive =
          installProgressTargetsSystemConfiguration(installProgress.phase);
      final systemConfigurationFailed =
          installFailureTargetsSystemConfiguration(installProgress);
      final projectKernelFailed =
          installProgress.phase == InstallPhase.failed &&
              !systemConfigurationFailed;
      return [
        DetailRow(
          label: details('projectKernel'),
          value: projectKernelFailed
              ? details('checkFailed')
              : projectKernelActive
                  ? details('inProgress')
                  : details('installed'),
          status: projectKernelFailed
              ? StatusKind.error
              : projectKernelActive
                  ? StatusKind.loading
                  : StatusKind.ok,
        ),
        DetailRow(
          label: details('grubIntegration'),
          value: systemConfigurationFailed
              ? details('checkFailed')
              : systemConfigurationActive
                  ? details('inProgress')
                  : details('pending'),
          status: systemConfigurationFailed
              ? StatusKind.error
              : systemConfigurationActive
                  ? StatusKind.loading
                  : StatusKind.pending,
        ),
        DetailRow(
          label: details('updateController'),
          value: manager.updater.controllerInstalled
              ? details('installed')
              : details('notInstalled'),
          status: manager.updater.controllerInstalled
              ? StatusKind.ok
              : StatusKind.warning,
        ),
      ];
    }

    if (installationInspection == InstallationInspection.error) {
      return [
        for (final label in [
          details('projectKernel'),
          details('grubIntegration'),
          details('updateController'),
        ])
          DetailRow(
            label: label,
            value: details('checkFailed'),
            status: StatusKind.error,
          ),
      ];
    }

    return [
      DetailRow(
        label: details('projectKernel'),
        value: projectKernelInstalled
            ? details('installed')
            : details('notInstalled'),
        status: projectKernelInstalled ? StatusKind.ok : StatusKind.warning,
      ),
      DetailRow(
        label: details('grubIntegration'),
        value: manager.grubConfigured
            ? details('configured')
            : details('notConfigured'),
        status: manager.grubConfigured ? StatusKind.ok : StatusKind.warning,
      ),
      DetailRow(
        label: details('updateController'),
        value: manager.updater.controllerInstalled
            ? details('installed')
            : details('notInstalled'),
        status: manager.updater.controllerInstalled
            ? StatusKind.ok
            : StatusKind.warning,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.manager;
    final t = context.t;
    String d(String key) => t.text('wizard.details.$key');
    final releaseIndexed = {
      DownloadPhase.downloading,
      DownloadPhase.paused,
      DownloadPhase.verifyingManifest,
      DownloadPhase.verifyingPackages,
      DownloadPhase.authorizingVersion,
      DownloadPhase.complete,
      DownloadPhase.packageManagerBusy,
      DownloadPhase.installFailed,
    }.contains(downloadPhase);
    final downloadComplete = {
      DownloadPhase.verifyingManifest,
      DownloadPhase.verifyingPackages,
      DownloadPhase.authorizingVersion,
      DownloadPhase.complete,
      DownloadPhase.packageManagerBusy,
      DownloadPhase.installFailed,
    }.contains(downloadPhase);
    final manifestVerified = {
      DownloadPhase.verifyingPackages,
      DownloadPhase.authorizingVersion,
      DownloadPhase.complete,
      DownloadPhase.packageManagerBusy,
      DownloadPhase.installFailed,
    }.contains(downloadPhase);
    final packagesVerified = {
      DownloadPhase.authorizingVersion,
      DownloadPhase.complete,
      DownloadPhase.packageManagerBusy,
      DownloadPhase.installFailed,
    }.contains(downloadPhase);
    final versionAuthorized = {
      DownloadPhase.complete,
      DownloadPhase.packageManagerBusy,
      DownloadPhase.installFailed,
    }.contains(downloadPhase);
    final noDownloadRequired = {
      DownloadPhase.current,
      DownloadPhase.rebootRequired,
      DownloadPhase.downgradeRefused,
    }.contains(downloadPhase);
    final failedRow = downloadPhase == DownloadPhase.failed
        ? checkFailureRowIndex(manager.updater.checkFailedPhase)
        : null;
    bool rowFailed(int row) => failedRow == row;
    bool rowCompletedBeforeFailure(int row) =>
        failedRow != null && row < failedRow;
    String? failureDescription(int row) =>
        rowFailed(row) ? manager.updater.lastCheckError : null;
    final terminalReleaseState = switch (downloadPhase) {
      DownloadPhase.current => d('currentVersion'),
      DownloadPhase.rebootRequired => d('installedRestartRequired'),
      DownloadPhase.packageManagerBusy => d('packageManagerBusy'),
      DownloadPhase.installFailed => d('installFailed'),
      DownloadPhase.releaseUnavailable => d('releaseUnavailable'),
      DownloadPhase.downgradeRefused => d('downgradeRefused'),
      DownloadPhase.unknown => t.text('overview.unknown'),
      _ => null,
    };
    final terminalReleaseStatus = switch (downloadPhase) {
      DownloadPhase.current => StatusKind.ok,
      DownloadPhase.rebootRequired ||
      DownloadPhase.packageManagerBusy ||
      DownloadPhase.installFailed ||
      DownloadPhase.releaseUnavailable ||
      DownloadPhase.downgradeRefused =>
        StatusKind.warning,
      _ => StatusKind.pending,
    };
    final installationTarget = switch (downloadPhase) {
      DownloadPhase.current ||
      DownloadPhase.rebootRequired ||
      DownloadPhase.downgradeRefused =>
        manager.updater.installedKernelRelease,
      _ => manager.updater.availableKernelRelease ??
          manager.updater.installedKernelRelease,
    };
    final fingerprintParts = manager.projectMokFingerprint?.split(':') ?? [];
    final abbreviatedFingerprint = fingerprintParts.length == 32
        ? '${fingerprintParts.take(8).join(':')}:...:${fingerprintParts.skip(28).join(':')}'
        : manager.projectMokFingerprint;
    final rows = switch (step) {
      0 => [
          DetailRow(
            label: '${t.text('overview.runningKernel')}('
                '${manager.snapshotLoaded && manager.activeKernel.version.isNotEmpty ? manager.activeKernel.version : t.text('overview.unknown')})',
            help: d('runningKernelHelp'),
            value: !manager.snapshotLoaded
                ? t.text('overview.unknown')
                : manager.runningKernelSupported
                    ? d('supported')
                    : d('unsupported'),
            status: !manager.snapshotLoaded
                ? StatusKind.pending
                : manager.runningKernelSupported
                    ? StatusKind.ok
                    : StatusKind.error,
          ),
          DetailRow(
            label: d('secureBoot'),
            help: d('secureBootHelp'),
            value: !manager.snapshotLoaded
                ? t.text('overview.unknown')
                : manager.secureBoot
                    ? d('enabled')
                    : d('disabled'),
            status: !manager.snapshotLoaded
                ? StatusKind.pending
                : manager.secureBoot
                    ? StatusKind.ok
                    : StatusKind.error,
          ),
          DetailRow(
            label: t.text('security.lockdownMode'),
            help: d('lockdownHelp'),
            value: !manager.snapshotLoaded
                ? t.text('overview.unknown')
                : manager.lockdown
                    ? t.text('security.integrityEnabled')
                    : t.text('security.disabled'),
            status: !manager.snapshotLoaded
                ? StatusKind.pending
                : manager.lockdown
                    ? StatusKind.ok
                    : StatusKind.error,
          ),
          DetailRow(
            label: t.text('security.luksState'),
            help: d('luksHelp'),
            value: !manager.snapshotLoaded
                ? t.text('overview.unknown')
                : manager.luks
                    ? t.text('security.encrypted')
                    : '${t.text('security.notEncrypted')} · ${d('recommended')}',
            status: !manager.snapshotLoaded
                ? StatusKind.pending
                : manager.luks
                    ? StatusKind.ok
                    : StatusKind.warning,
          ),
          DetailRow(
            label: d('hibernationSpace'),
            help: d('hibernationSpaceHelp'),
            value: !manager.snapshotLoaded
                ? t.text('overview.unknown')
                : manager.hibernationCapacity
                    ? d('ready')
                    : d('attention'),
            status: !manager.snapshotLoaded
                ? StatusKind.pending
                : manager.hibernationCapacity
                    ? StatusKind.ok
                    : StatusKind.error,
          ),
          DetailRow(
            label: d('officialFallback'),
            help: d('officialFallbackHelp'),
            value: !manager.snapshotLoaded
                ? t.text('overview.unknown')
                : manager.officialFallbackInstalled
                    ? d('installed')
                    : d('missing'),
            status: !manager.snapshotLoaded
                ? StatusKind.pending
                : manager.officialFallbackInstalled
                    ? StatusKind.ok
                    : StatusKind.error,
          ),
        ],
      1 => [
          DetailRow(
            label: d('updatePolicy'),
            description: d('updatePolicyDescription'),
            control: AppSelect<UpdatePolicy>(
              value: manager.updatePolicy,
              options: [
                AppSelectOption(UpdatePolicy.manual, d('manualPolicy')),
                AppSelectOption(UpdatePolicy.checkAndNotify, d('notifyPolicy')),
                AppSelectOption(
                    UpdatePolicy.automaticInstall, d('automaticPolicy')),
              ],
              onChanged: manager.setUpdatePolicy,
            ),
          ),
          DetailRow(
            label: d('kernelRetention'),
            description: d('kernelRetentionDescription'),
            value: d('enabled'),
            status: StatusKind.ok,
          ),
          DetailRow(
            label: d('fallbackLocked'),
            description: d('fallbackLockedDescription'),
            value: d('enabled'),
            status: StatusKind.ok,
          ),
          DetailRow(
            label: d('configureTpm'),
            description: manager.luks
                ? d('configureTpmDescription')
                : d('tpmUnavailableWithoutLuks'),
            control: AppSwitch(
              value: manager.configureTpm,
              onChanged: manager.luks ? manager.setConfigureTpm : null,
            ),
          ),
        ],
      2 => [
          DetailRow(
            label: d('latestRelease'),
            description: failureDescription(0),
            value: rowFailed(0)
                ? d('checkFailed')
                : terminalReleaseState ??
                    (downloadPhase == DownloadPhase.indexing
                        ? d('indexingRelease')
                        : releaseIndexed || rowCompletedBeforeFailure(0)
                            ? d('releaseFound')
                            : d('pending')),
            status: rowFailed(0)
                ? StatusKind.error
                : terminalReleaseState != null
                    ? terminalReleaseStatus
                    : downloadPhase == DownloadPhase.indexing
                        ? StatusKind.loading
                        : releaseIndexed || rowCompletedBeforeFailure(0)
                            ? StatusKind.ok
                            : StatusKind.pending,
          ),
          DetailRow(
            label: d('packageDownload'),
            description: failureDescription(1),
            value: noDownloadRequired
                ? d('notRequired')
                : rowFailed(1)
                    ? d('checkFailed')
                    : downloadComplete || rowCompletedBeforeFailure(1)
                        ? d('downloaded')
                        : downloadPhase == DownloadPhase.downloading
                            ? t.text('wizard.details.downloadingProgress',
                                {'progress': downloadProgress})
                            : downloadPhase == DownloadPhase.paused
                                ? t.text('wizard.details.pausedProgress',
                                    {'progress': downloadProgress})
                                : d('pending'),
            status: noDownloadRequired
                ? StatusKind.ok
                : rowFailed(1)
                    ? StatusKind.error
                    : downloadComplete || rowCompletedBeforeFailure(1)
                        ? StatusKind.ok
                        : downloadPhase == DownloadPhase.downloading
                            ? StatusKind.loading
                            : StatusKind.pending,
          ),
          DetailRow(
            label: d('signedManifest'),
            description: failureDescription(2),
            value: noDownloadRequired
                ? d('notRequired')
                : rowFailed(2)
                    ? d('checkFailed')
                    : manifestVerified || rowCompletedBeforeFailure(2)
                        ? d('verified')
                        : downloadPhase == DownloadPhase.verifyingManifest
                            ? d('verifying')
                            : d('pending'),
            status: noDownloadRequired
                ? StatusKind.ok
                : rowFailed(2)
                    ? StatusKind.error
                    : manifestVerified || rowCompletedBeforeFailure(2)
                        ? StatusKind.ok
                        : downloadPhase == DownloadPhase.verifyingManifest
                            ? StatusKind.loading
                            : StatusKind.pending,
          ),
          DetailRow(
            label: d('packageIntegrity'),
            description: failureDescription(3),
            value: noDownloadRequired
                ? d('notRequired')
                : rowFailed(3)
                    ? d('checkFailed')
                    : packagesVerified || rowCompletedBeforeFailure(3)
                        ? d('verified')
                        : downloadPhase == DownloadPhase.verifyingPackages
                            ? d('verifying')
                            : d('pending'),
            status: noDownloadRequired
                ? StatusKind.ok
                : rowFailed(3)
                    ? StatusKind.error
                    : packagesVerified || rowCompletedBeforeFailure(3)
                        ? StatusKind.ok
                        : downloadPhase == DownloadPhase.verifyingPackages
                            ? StatusKind.loading
                            : StatusKind.pending,
          ),
          DetailRow(
            label: d('versionAuthorization'),
            description: failureDescription(4),
            value: noDownloadRequired
                ? manager.updater.installedSourceVersion ?? d('notRequired')
                : rowFailed(4)
                    ? d('checkFailed')
                    : versionAuthorized || rowCompletedBeforeFailure(4)
                        ? manager.updater.availableSourceVersion ??
                            d('authorized')
                        : downloadPhase == DownloadPhase.authorizingVersion
                            ? d('verifying')
                            : d('pending'),
            status: noDownloadRequired
                ? StatusKind.ok
                : rowFailed(4)
                    ? StatusKind.error
                    : versionAuthorized || rowCompletedBeforeFailure(4)
                        ? StatusKind.ok
                        : downloadPhase == DownloadPhase.authorizingVersion
                            ? StatusKind.loading
                            : StatusKind.pending,
          ),
        ],
      3 => [
          DetailRow(
            label: d('projectCertificate'),
            description: abbreviatedFingerprint == null
                ? null
                : t.text('wizard.details.certificateFingerprint', {
                    'fingerprint': abbreviatedFingerprint,
                  }),
            value: manager.projectMokStatus == ProjectMokStatus.enrolled
                ? t.text('security.enrolled')
                : manager.projectMokStatus == ProjectMokStatus.pendingEnrollment
                    ? usesLegacyMokPassword(manager.mokOneTimePassword)
                        ? t.text('wizard.passwordUpdateRequired')
                        : t.text('wizard.restartRequired')
                    : manager.projectMokStatus == ProjectMokStatus.missing
                        ? t.text('security.missing')
                        : t.text('overview.unknown'),
            status: manager.projectMokStatus == ProjectMokStatus.enrolled
                ? StatusKind.ok
                : manager.projectMokStatus == ProjectMokStatus.missing ||
                        manager.projectMokStatus ==
                            ProjectMokStatus.pendingEnrollment
                    ? StatusKind.warning
                    : StatusKind.pending,
          ),
          if (manager.mokOneTimePassword != null)
            DetailRow(
              label: d('mokOneTimePassword'),
              description: d('mokOneTimePasswordDescription'),
              value: manager.mokOneTimePassword,
              valueStyle: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontFamily: 'Ubuntu',
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
              status: StatusKind.warning,
              statusIcon: LucideIcons.lock,
              statusColor: Theme.of(context).colorScheme.error,
            ),
        ],
      4 => _installationRows(
          manager: manager,
          installationTarget: installationTarget,
          details: d,
        ),
      5 => [
          DetailRow(
            label: d('runningProjectKernel'),
            description: manager.activeKernel.version,
            value: bootVerified ? d('ready') : d('attention'),
            status: bootVerified ? StatusKind.ok : StatusKind.error,
          ),
          DetailRow(
            label: d('secureBoot'),
            value: manager.secureBoot ? d('enabled') : d('disabled'),
            status: manager.secureBoot ? StatusKind.ok : StatusKind.error,
          ),
          DetailRow(
            label: t.text('security.lockdownMode'),
            value: manager.lockdown
                ? t.text('security.integrityEnabled')
                : t.text('security.disabled'),
            status: manager.lockdown ? StatusKind.ok : StatusKind.error,
          ),
          DetailRow(
            label: d('officialFallback'),
            value: manager.officialFallbackInstalled
                ? d('installed')
                : d('missing'),
            status: manager.officialFallbackInstalled
                ? StatusKind.ok
                : StatusKind.error,
          ),
        ],
      _ => [
          DetailRow(
            label: d('configureTpm'),
            description: manager.luks
                ? d('configureTpmDescription')
                : d('tpmUnavailableWithoutLuks'),
            value: !manager.luks
                ? d('notApplicable')
                : !manager.configureTpm
                    ? d('disabled')
                    : processing && tpmInspection == TpmInspection.unchecked
                        ? t.text('common.checkingStatus')
                        : switch (tpmInspection) {
                            TpmInspection.unchecked => d('tpmUnchecked'),
                            TpmInspection.configured => d('configured'),
                            TpmInspection.needsConfiguration =>
                              d('tpmNeedsConfiguration'),
                          },
            status: !manager.luks
                ? StatusKind.warning
                : !manager.configureTpm
                    ? StatusKind.warning
                    : tpmInspection == TpmInspection.configured
                        ? StatusKind.ok
                        : tpmInspection == TpmInspection.needsConfiguration
                            ? StatusKind.warning
                            : StatusKind.pending,
          ),
          DetailRow(
            label: t.text('security.luksState'),
            help: d('luksHelp'),
            value: manager.luks
                ? t.text('security.encrypted')
                : '${t.text('security.notEncrypted')} · ${d('recommended')}',
            status: manager.luks ? StatusKind.ok : StatusKind.warning,
          ),
          DetailRow(
            label: t.text('security.tpmBinding'),
            description: d('crypttabDescription'),
            value: !manager.luks
                ? d('notApplicable')
                : tpmInspection == TpmInspection.configured
                    ? d('tpmVerified')
                    : manager.tpmConfigured
                        ? d('crypttabDetected')
                        : d('crypttabNotDetected'),
            status: !manager.luks
                ? StatusKind.warning
                : tpmInspection == TpmInspection.configured
                    ? StatusKind.ok
                    : manager.tpmConfigured
                        ? StatusKind.warning
                        : StatusKind.pending,
          ),
          DetailRow(
            label: d('passwordRecovery'),
            value: !manager.luks
                ? d('notApplicable')
                : recoveryVerified
                    ? d('recoveryVerified')
                    : d('recoveryUnverified'),
            status: !manager.luks
                ? StatusKind.warning
                : recoveryVerified
                    ? StatusKind.ok
                    : StatusKind.pending,
          ),
        ],
    };
    return Column(children: rows);
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow({
    required this.label,
    this.value,
    this.description,
    this.help,
    this.status,
    this.control,
    this.valueStyle,
    this.statusIcon,
    this.statusColor,
    super.key,
  });

  final String label;
  final String? value;
  final String? description;
  final String? help;
  final StatusKind? status;
  final Widget? control;
  final TextStyle? valueStyle;
  final IconData? statusIcon;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: context.palette.textStrong,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (help != null)
              Tooltip(
                message: help!,
                waitDuration: const Duration(milliseconds: 250),
                child: Icon(
                  LucideIcons.circleHelp,
                  size: 15,
                  color: context.palette.textMuted,
                ),
              ),
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(description!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
    final trailing = control ??
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status != null) ...[
              StatusGlyph(
                status!,
                size: 14,
                icon: statusIcon,
                color: statusColor,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                value ?? '',
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: statusColor ?? _statusColor(context, status),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ).merge(valueStyle),
              ),
            ),
          ],
        );
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: trailing),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 20),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: trailing,
              ),
            ],
          );
        },
      ),
    );
  }

  Color _statusColor(BuildContext context, StatusKind? status) =>
      switch (status) {
        StatusKind.ok => context.palette.dark
            ? const Color(0xff34d399)
            : const Color(0xff047857),
        StatusKind.warning => context.palette.dark
            ? const Color(0xfffbbf24)
            : const Color(0xffb45309),
        StatusKind.error => context.palette.dark
            ? const Color(0xfff87171)
            : const Color(0xffb91c1c),
        _ => context.palette.textMedium,
      };
}

Future<void> showPreflightDialog(BuildContext context) async {
  final manager = context.manager;
  final t = context.t;
  Future<String> recheck() async {
    try {
      await manager.refreshSnapshot();
      return formatPreflightLog(manager);
    } on Object catch (error) {
      return '${formatPreflightLog(manager)}\n\n[RECHECK ERROR]\n$error';
    }
  }

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: t.text('common.close'),
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        _PreflightDialog(
      title: t.text('wizard.logDialogTitle'),
      log: formatPreflightLog(manager),
      onRecheck: recheck,
      copyTooltip: t.text('common.copy'),
      copiedTooltip: t.text('common.copied'),
      recheckTooltip: t.text('common.recheck'),
      closeTooltip: t.text('common.close'),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curve =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.985, end: 1.0).animate(curve),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.025), end: Offset.zero)
                .animate(curve),
            child: child,
          ),
        ),
      );
    },
  );
}

String formatPreflightLog(ManagerController manager) {
  final official = manager.kernels
      .where((kernel) =>
          !kernel.project && kernel.status != KernelStatus.available)
      .map((kernel) => kernel.version)
      .toList();
  final checks = <({
    String id,
    String source,
    String expected,
    String observed,
    String failure,
    bool passed,
  })>[
    (
      id: 'running_kernel',
      source: '/proc/sys/kernel/osrelease',
      expected: 'Linux >= 7.0.0',
      observed: manager.activeKernel.version.isEmpty
          ? 'not detected'
          : manager.activeKernel.version,
      failure:
          'running Linux kernel is older than 7.0.0 or could not be parsed',
      passed: manager.runningKernelSupported,
    ),
    (
      id: 'secure_boot',
      source: '/usr/bin/mokutil --sb-state',
      expected: 'enabled',
      observed: manager.secureBoot ? 'enabled' : 'disabled',
      failure: 'UEFI Secure Boot is disabled or could not be verified',
      passed: manager.secureBoot,
    ),
    (
      id: 'kernel_lockdown',
      source: '/sys/kernel/security/lockdown',
      expected: 'integrity or confidentiality',
      observed: manager.lockdown ? 'active' : 'disabled',
      failure: 'kernel Lockdown is not active',
      passed: manager.lockdown,
    ),
    (
      id: 'luks_root',
      source: '/usr/bin/lsblk --json --output NAME,TYPE,FSTYPE,MOUNTPOINTS',
      expected: 'root filesystem backed by LUKS',
      observed: manager.luks ? 'encrypted' : 'not encrypted',
      failure: 'no LUKS mapping was detected in the root device ancestry',
      passed: manager.luks,
    ),
    (
      id: 'hibernation_capacity',
      source: '/proc/meminfo + /proc/swaps',
      expected: 'non-zram disk swap >= MemTotal',
      observed: manager.hibernationCapacity
          ? 'sufficient'
          : 'insufficient or unavailable',
      failure:
          'disk-backed swap capacity does not satisfy the memory requirement',
      passed: manager.hibernationCapacity,
    ),
    (
      id: 'official_kernel_fallback',
      source: '/usr/bin/dpkg-query linux-image-*',
      expected: 'at least one installed official Ubuntu kernel',
      observed: official.isEmpty ? 'none detected' : official.join(', '),
      failure: 'no installed official Ubuntu kernel was detected',
      passed: official.isNotEmpty,
    ),
  ];
  final failed =
      checks.where((check) => !check.passed && check.id != 'luks_root').length;
  final warned =
      checks.where((check) => !check.passed && check.id == 'luks_root').length;
  final passed = checks.where((check) => check.passed).length;
  final lines = <String>[
    'secure-hibernate-manager preflight',
    'report_generated_at=${DateTime.now().toUtc().toIso8601String()}',
    'backend=${manager.backendConnection.name}',
    'result=${manager.backendConnection == BackendConnection.error || failed > 0 ? 'FAIL' : warned > 0 ? 'WARN' : 'PASS'}',
    'checks_total=${checks.length}',
    'checks_passed=$passed',
    'checks_warned=$warned',
    'checks_failed=$failed',
  ];
  for (final check in checks) {
    final warning = !check.passed && check.id == 'luks_root';
    lines.addAll([
      '',
      '[${check.passed ? 'PASS' : warning ? 'WARN' : 'FAIL'}] ${check.id}',
      'source=${jsonEncode(check.source)}',
      'expected=${jsonEncode(check.expected)}',
      'observed=${jsonEncode(check.observed)}',
      if (!check.passed)
        '${warning ? 'warning' : 'error'}=${jsonEncode(check.failure)}',
    ]);
  }
  if (manager.collectorWarnings.isNotEmpty) {
    lines.addAll(['', '[COLLECTOR]', ...manager.collectorWarnings]);
  }
  if (manager.preflightDiagnostics.isNotEmpty) {
    lines.addAll(['', '[RAW DIAGNOSTICS]']);
    for (final diagnostic in manager.preflightDiagnostics) {
      final invocation = diagnostic.operation == 'execFile'
          ? 'execFile(${[
              diagnostic.source,
              ...diagnostic.arguments
            ].map(jsonEncode).join(', ')})'
          : 'readFile(${jsonEncode(diagnostic.source)})';
      lines.addAll([
        '',
        '[${diagnostic.id}]',
        invocation,
        'exit_code=${diagnostic.exitCode ?? 'unavailable'}',
        if (diagnostic.stdout.isNotEmpty) ...[
          '--- stdout (raw) ---',
          diagnostic.stdout,
        ],
        if (diagnostic.stderr.isNotEmpty) ...[
          '--- stderr (raw) ---',
          diagnostic.stderr,
        ],
        if (diagnostic.error != null) ...[
          '--- runtime error (raw) ---',
          diagnostic.error!,
        ],
      ]);
    }
  }
  return lines.join('\n');
}

class _PreflightDialog extends StatefulWidget {
  const _PreflightDialog({
    required this.title,
    required this.log,
    required this.onRecheck,
    required this.copyTooltip,
    required this.copiedTooltip,
    required this.recheckTooltip,
    required this.closeTooltip,
  });

  final String title;
  final String log;
  final Future<String> Function() onRecheck;
  final String copyTooltip;
  final String copiedTooltip;
  final String recheckTooltip;
  final String closeTooltip;

  @override
  State<_PreflightDialog> createState() => _PreflightDialogState();
}

class _PreflightDialogState extends State<_PreflightDialog>
    with SingleTickerProviderStateMixin {
  bool copied = false;
  late final AnimationController spin;
  late String log;

  @override
  void initState() {
    super.initState();
    log = widget.log;
    spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
  }

  @override
  void dispose() {
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 672,
          maxHeight: MediaQuery.sizeOf(context).height.clamp(200, 576),
        ),
        child: Material(
          key: const ValueKey('preflight-dialog'),
          color: context.palette.card,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: context.palette.strongBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            style: TextStyle(
                              color: context.palette.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        _DialogIconButton(
                          icon: copied ? LucideIcons.check : LucideIcons.copy,
                          color: copied ? const Color(0xff059669) : null,
                          tooltip: copied
                              ? widget.copiedTooltip
                              : widget.copyTooltip,
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: log),
                            );
                            if (mounted) setState(() => copied = true);
                          },
                        ),
                        RotationTransition(
                          turns: spin,
                          child: _DialogIconButton(
                            icon: LucideIcons.refreshCw,
                            tooltip: widget.recheckTooltip,
                            onPressed: () async {
                              spin.repeat();
                              try {
                                final refreshed = await widget.onRecheck();
                                if (mounted) setState(() => log = refreshed);
                              } finally {
                                if (mounted) {
                                  await spin.animateTo(
                                    spin.value.ceilToDouble(),
                                    duration: const Duration(milliseconds: 160),
                                  );
                                  spin.stop();
                                  spin.value = 0;
                                }
                              }
                            },
                          ),
                        ),
                        _DialogIconButton(
                          key: const ValueKey('preflight-dialog-close'),
                          icon: LucideIcons.x,
                          tooltip: widget.closeTooltip,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: Neutral.n950,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: SelectableText(
                          log,
                          style: const TextStyle(
                            color: Neutral.n100,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 2,
                          ),
                        ),
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
}

class _DialogIconButton extends StatelessWidget {
  const _DialogIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 16,
            color: color ?? context.palette.textMuted,
          ),
        ),
      ),
    );
  }
}
