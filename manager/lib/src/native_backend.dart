import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'backend.dart';

const _appId = 'io.github.xiaoyueyoqwq.secure-hibernate-manager';
const _autostartMarker = 'X-SecureHibernate-SetupResume=true';
const _helperPath =
    '/usr/local/lib/s4lockdown-update/scripts/manager-helper.py';
const _pkexecPath = '/usr/bin/pkexec';
const _projectFingerprint =
    '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
    'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11';

final _projectReleasePattern = RegExp(r'^[0-9][0-9A-Za-z.+~-]*-s4lockdown$');
final _sourceVersionPattern = RegExp(r'^[0-9][0-9A-Za-z.+:~-]*$');
final _fingerprintPattern = RegExp(r'^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$');

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class CommandRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout,
    List<int>? stdinBytes,
  });
}

class IoCommandRunner implements CommandRunner {
  const IoCommandRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    List<int>? stdinBytes,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    if (stdinBytes != null) process.stdin.add(stdinBytes);
    await process.stdin.close();
    final stdoutFuture = utf8.decoder.bind(process.stdout).join();
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      throw TimeoutException(
        '$executable exceeded ${timeout.inSeconds} seconds',
        timeout,
      );
    }
    final output = await Future.wait([stdoutFuture, stderrFuture]);
    if (output[0].length > 4 * 1024 * 1024 ||
        output[1].length > 4 * 1024 * 1024) {
      throw StateError('$executable produced excessive output');
    }
    return CommandResult(
      exitCode: exitCode,
      stdout: output[0],
      stderr: output[1],
    );
  }
}

InstallProgress parseInstallProgressState(Map<String, dynamic> state) {
  final phaseValue = state['install_phase'];
  final progressValue = state['install_progress'];
  if (phaseValue == null && progressValue == null) {
    return const InstallProgress.idle();
  }
  if (phaseValue is! String || progressValue is! int) {
    throw const FormatException('Invalid installation progress state');
  }
  final phase = switch (phaseValue) {
    'preparing' => InstallPhase.preparing,
    'indexing-release' => InstallPhase.indexingRelease,
    'downloading-release' => InstallPhase.downloadingRelease,
    'verifying-manifest' => InstallPhase.verifyingManifest,
    'verifying-download-packages' => InstallPhase.verifyingDownloadPackages,
    'authorizing-version' => InstallPhase.authorizingVersion,
    'verifying-release' => InstallPhase.verifyingRelease,
    'verifying-packages' => InstallPhase.verifyingPackages,
    'installing-packages' => InstallPhase.installingPackages,
    'configuring-system' => InstallPhase.configuringSystem,
    'complete' => InstallPhase.complete,
    'failed' => InstallPhase.failed,
    _ => throw FormatException('Unsupported installation phase: $phaseValue'),
  };
  if (progressValue < 0 || progressValue > 100) {
    throw const FormatException('Installation progress is outside 0..100');
  }
  const fixedProgress = {
    InstallPhase.preparing: 5,
    InstallPhase.indexingRelease: 8,
    InstallPhase.verifyingManifest: 58,
    InstallPhase.verifyingDownloadPackages: 62,
    InstallPhase.authorizingVersion: 64,
    InstallPhase.verifyingRelease: 65,
    InstallPhase.verifyingPackages: 70,
    InstallPhase.installingPackages: 78,
    InstallPhase.configuringSystem: 90,
    InstallPhase.complete: 100,
  };
  final validDownloadProgress = phase == InstallPhase.downloadingRelease &&
      progressValue >= 8 &&
      progressValue <= 55;
  if (phase != InstallPhase.failed &&
      !validDownloadProgress &&
      fixedProgress[phase] != progressValue) {
    throw const FormatException('Installation phase and progress disagree');
  }
  final updatedAt = state['install_updated_at'];
  if (updatedAt != null && updatedAt is! String) {
    throw const FormatException('Invalid installation progress timestamp');
  }
  return InstallProgress(
    phase: phase,
    progress: progressValue,
    updatedAt: updatedAt as String?,
  );
}

const _runningUpdaterCheckStatuses = {
  'indexing',
  'downloading',
  'verifying-manifest',
  'verifying-packages',
  'authorizing-version',
};

bool updaterCheckStateIsRunning(Object? status) =>
    status is String && _runningUpdaterCheckStatuses.contains(status);

Map<String, dynamic> authoritativeUpdaterCheckState(
  Map<String, dynamic> initial, {
  required bool checkServiceActive,
  Map<String, dynamic>? refreshed,
}) {
  if (checkServiceActive || !updaterCheckStateIsRunning(initial['status'])) {
    return initial;
  }
  final refreshedStatus = refreshed?['status'];
  if (refreshedStatus is String &&
      !updaterCheckStateIsRunning(refreshedStatus)) {
    return refreshed!;
  }
  return initial;
}

class NativeManagerBackend implements ManagerBackend {
  NativeManagerBackend({
    CommandRunner? commandRunner,
    Map<String, String>? environment,
  })  : _commands = commandRunner ?? const IoCommandRunner(),
        _environment = environment ?? Platform.environment;

  final CommandRunner _commands;
  final Map<String, String> _environment;
  Future<ManagerActionResult>? _activeManagerAction;
  bool _passwordRecoveryVerified = false;
  bool _tpmUnlockVerified = false;

  String get _configRoot {
    final configured = _environment['XDG_CONFIG_HOME'];
    if (configured != null && configured.startsWith('/') && configured != '/') {
      return configured;
    }
    final home = _environment['HOME'];
    if (home == null || !home.startsWith('/') || home == '/') {
      throw StateError('HOME does not identify a specific absolute directory');
    }
    return '$home/.config';
  }

  String get _progressPath =>
      '$_configRoot/secure-hibernate-manager/setup-progress.json';
  String get _autostartPath => '$_configRoot/autostart/$_appId.desktop';

  @override
  Future<SystemSnapshot> getSnapshot() => _collectSystemSnapshot();

  @override
  Future<InstallProgress> getInstallProgress() async {
    const path = '/var/lib/s4lockdown-update/state.json';
    Map<String, dynamic> state;
    try {
      state = await _readJsonObject(path);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) {
        return const InstallProgress.idle();
      }
      rethrow;
    }
    return parseInstallProgressState(state);
  }

  @override
  Future<ProjectMokInspection> inspectProjectMok() async {
    final result = await runManagerAction(
      const ManagerActionRequest(ManagerActionType.inspectMok),
    );
    if (result.status == ManagerActionStatus.cancelled) {
      return const ProjectMokInspection(
        status: ProjectMokStatus.cancelled,
        fingerprintSha256: null,
        error: null,
        oneTimePassword: null,
      );
    }
    if (result.status == ManagerActionStatus.error) {
      return ProjectMokInspection(
        status: ProjectMokStatus.error,
        fingerprintSha256: null,
        error: result.error,
        oneTimePassword: null,
      );
    }
    final data = result.data;
    final status = switch (data.mokStatus) {
      'enrolled' => ProjectMokStatus.enrolled,
      'pending' when data.oneTimePassword != null =>
        ProjectMokStatus.pendingEnrollment,
      'not-pending' => ProjectMokStatus.missing,
      _ => ProjectMokStatus.error,
    };
    return ProjectMokInspection(
      status: status,
      fingerprintSha256:
          status == ProjectMokStatus.error ? null : data.fingerprintSha256,
      error: status == ProjectMokStatus.error
          ? 'Privileged helper returned an incomplete MOK inspection result'
          : null,
      oneTimePassword: data.oneTimePassword,
    );
  }

  @override
  Future<ManagerActionResult> runManagerAction(
    ManagerActionRequest request,
  ) async {
    _validateActionRequest(request);
    if (_activeManagerAction != null) {
      return ManagerActionResult(
        action: request.action,
        status: ManagerActionStatus.error,
        error: 'Another privileged Manager action is active',
        data: const ManagerActionData(),
      );
    }
    final action = _executeManagerAction(request);
    _activeManagerAction = action;
    try {
      final result = await action;
      if (result.status == ManagerActionStatus.success) {
        if (result.action == ManagerActionType.verifyRecovery) {
          _passwordRecoveryVerified = true;
        } else if (result.action == ManagerActionType.verifyTpm) {
          _tpmUnlockVerified = true;
        } else if (result.action == ManagerActionType.enrollTpm) {
          _passwordRecoveryVerified = true;
          _tpmUnlockVerified = true;
        }
      }
      return result;
    } finally {
      _activeManagerAction = null;
    }
  }

  Future<ManagerActionResult> _executeManagerAction(
    ManagerActionRequest request,
  ) async {
    try {
      if (!await _isSecureHelper()) {
        return _actionError(
          request,
          'The native Manager backend is not installed securely. '
          'Install or refresh the update controller.',
        );
      }
    } on FileSystemException catch (error) {
      return _actionError(
        request,
        error.osError?.errorCode == 2
            ? 'The native Manager backend is not installed. '
                'Install or refresh the update controller.'
            : 'The native Manager backend could not be inspected: $error',
      );
    } on Object catch (error) {
      return _actionError(
        request,
        'The native Manager backend could not be inspected: $error',
      );
    }

    final arguments = <String>[_helperPath, request.action.wireValue];
    if (request.action == ManagerActionType.setPolicy) {
      arguments.add(request.policy!.wireValue);
    } else if (request.action == ManagerActionType.setKernelRetention) {
      arguments.add(request.projectKernelHistory!.toString());
    } else if (request.action == ManagerActionType.removeKernel) {
      arguments.add(request.release!);
    } else if (request.recoveryPassword != null) {
      arguments.add('--password-stdin');
    }

    try {
      final result = await _commands.run(
        _pkexecPath,
        arguments,
        timeout: const Duration(hours: 2),
        stdinBytes: request.recoveryPassword,
      );
      if (result.exitCode == 126) {
        return ManagerActionResult(
          action: request.action,
          status: ManagerActionStatus.cancelled,
          error: null,
          data: const ManagerActionData(),
        );
      }
      try {
        final parsed =
            parseManagerActionResponse(request, result.stdout.trim());
        if (result.exitCode != 0 &&
            parsed.status != ManagerActionStatus.error) {
          return _actionError(
            request,
            result.stderr.trim().isEmpty
                ? 'Privileged helper exited with status ${result.exitCode}'
                : result.stderr.trim(),
          );
        }
        return parsed;
      } on Object catch (error) {
        final detail = result.stderr.trim();
        return _actionError(
          request,
          detail.isNotEmpty ? detail : error.toString(),
        );
      }
    } on Object catch (error) {
      return _actionError(request, error.toString());
    }
  }

  @override
  Future<SetupProgress> getSetupProgress() async {
    final file = File(_progressPath);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const SetupProgress(checkpoint: null, completed: false);
    }
    if (type != FileSystemEntityType.file) {
      throw StateError('Setup progress is not a regular file');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != 1 ||
        decoded['completed'] is! bool ||
        (decoded['checkpoint'] != null && decoded['checkpoint'] is! String)) {
      throw const FormatException(
          'Setup progress has an unsupported structure');
    }
    SetupCheckpoint? checkpoint;
    if (decoded['checkpoint'] case final String value) {
      checkpoint = SetupCheckpointWireValue.parse(value);
    }
    return SetupProgress(
      checkpoint: checkpoint,
      completed: decoded['completed'] as bool,
    );
  }

  @override
  Future<SetupProgress> saveSetupCheckpoint(SetupCheckpoint checkpoint) async {
    final progress = SetupProgress(checkpoint: checkpoint, completed: false);
    await _writeProgress(progress);
    try {
      await _installAutostart();
    } on Object {
      await clearSetupCheckpoint();
      rethrow;
    }
    return progress;
  }

  @override
  Future<SetupProgress> clearSetupCheckpoint() async {
    final current = await getSetupProgress();
    final progress = SetupProgress(
      checkpoint: null,
      completed: current.completed,
    );
    await _writeProgress(progress);
    await _removeAutostart();
    return progress;
  }

  @override
  Future<SetupProgress> completeSetup(bool requireTpm) async {
    final snapshot = await _collectSystemSnapshot();
    assertSetupCanComplete(
      snapshot,
      requireTpm,
      passwordRecoveryVerified: _passwordRecoveryVerified,
      tpmUnlockVerified: _tpmUnlockVerified,
    );
    const progress = SetupProgress(checkpoint: null, completed: true);
    await _writeProgress(progress);
    await _removeAutostart();
    return progress;
  }

  @override
  Future<SystemActionResult> restartForSetup(
    SetupCheckpoint checkpoint,
  ) async {
    await saveSetupCheckpoint(checkpoint);
    try {
      final result = await _commands.run(
        _pkexecPath,
        const ['/usr/bin/systemctl', 'reboot'],
        timeout: const Duration(minutes: 5),
      );
      if (result.exitCode == 0) {
        return const SystemActionResult(
          status: SystemActionStatus.started,
          error: null,
        );
      }
      if (result.exitCode == 126) {
        return const SystemActionResult(
          status: SystemActionStatus.cancelled,
          error: null,
        );
      }
      return SystemActionResult(
        status: SystemActionStatus.error,
        error: result.stderr.trim().isEmpty
            ? 'Restart command exited with status ${result.exitCode}'
            : result.stderr.trim(),
      );
    } on Object catch (error) {
      return SystemActionResult(
        status: SystemActionStatus.error,
        error: error.toString(),
      );
    }
  }

  @override
  Future<ExportResult> exportDiagnostics() async {
    final snapshot = await getSnapshot();
    final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final location = await getSaveLocation(
      suggestedName: 'secure-hibernate-diagnostics-$date.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) {
      return const ExportResult(status: ExportStatus.cancelled, path: null);
    }
    try {
      final report = <String, Object?>{
        'schemaVersion': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'snapshot': _snapshotToJson(snapshot),
      };
      await _writeAtomic(
        location.path,
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        createParent: false,
      );
      return ExportResult(
        status: ExportStatus.saved,
        path: location.path,
      );
    } on Object catch (error) {
      return ExportResult(
        status: ExportStatus.error,
        path: null,
        error: error.toString(),
      );
    }
  }

  Future<SystemSnapshot> _collectSystemSnapshot() async {
    final warnings = <String>[];
    final diagnostics = <PreflightDiagnostic>[];
    final activeRelease = await _capture(
      'Running kernel',
      () => _readDiagnosticFile(
        '/proc/sys/kernel/osrelease',
        'running-kernel',
        diagnostics,
      ).then((value) => value.trim()),
      Platform.operatingSystemVersion,
      warnings,
    );
    final state = await _capture(
      'Updater state',
      () => _readJsonObject('/var/lib/s4lockdown-update/state.json'),
      <String, dynamic>{},
      warnings,
    );
    var checkState = await _capture(
      'Updater check state',
      () => _readJsonObject('/var/cache/s4lockdown-update/check-state.json'),
      <String, dynamic>{},
      warnings,
    );

    final ubuntuVersion = await _capture(
      'Operating system',
      _readOperatingSystem,
      'Unknown Linux',
      warnings,
    );
    final secureBoot = await _capture(
      'Secure Boot',
      () => _readSecureBoot(diagnostics),
      false,
      warnings,
    );
    final lockdown = await _capture(
      'Kernel lockdown',
      () => _readLockdown(diagnostics),
      false,
      warnings,
    );
    final luks = await _capture(
      'LUKS root device',
      () => _readLuksState(diagnostics),
      false,
      warnings,
    );
    final tpmConfigured = await _capture(
      'TPM crypttab binding',
      _readTpmBinding,
      false,
      warnings,
    );
    final hibernatePartition = await _capture(
      'Hibernate capacity',
      () => _readHibernateCapacity(diagnostics),
      false,
      warnings,
    );
    final grubUpdated = await _capture(
      'GRUB integration',
      _readGrubIntegration,
      false,
      warnings,
    );
    final policy = await _capture(
      'Updater policy',
      _readUpdatePolicy,
      UpdatePolicy.manual,
      warnings,
    );
    final timer = await _capture(
      'Updater timer',
      _readTimerStatus,
      const _TimerStatus(),
      warnings,
    );
    final checkServices = await _capture(
      'Updater check services',
      _readCheckServicesStatus,
      const _ServiceStatus(),
      warnings,
    );
    if (!checkServices.active &&
        updaterCheckStateIsRunning(checkState['status'])) {
      final refreshedCheckState = await _capture(
        'Updater terminal check state',
        () => _readJsonObject(
          '/var/cache/s4lockdown-update/check-state.json',
        ),
        <String, dynamic>{},
        warnings,
      );
      checkState = authoritativeUpdaterCheckState(
        checkState,
        checkServiceActive: false,
        refreshed: refreshedCheckState,
      );
    }
    final helperInstalled = await _capture(
      'Manager helper',
      _isSecureHelper,
      false,
      warnings,
    );
    final installed = await _capture(
      'Installed kernels',
      () => _readInstalledKernels(activeRelease, state, diagnostics),
      _InstalledKernelState(
        kernels: [
          KernelInfo(
            id: 'running-$activeRelease',
            version: activeRelease,
            project: activeRelease.contains('s4lockdown'),
            status: KernelStatus.active,
          ),
        ],
        projectHeadersInstalled: false,
      ),
      warnings,
    );

    final installedRelease =
        _nullableString(state['installed_kernel_release']) ??
            installed.installedProjectRelease;
    final installedSourceVersion =
        _nullableString(state['installed_source_version']) ??
            installed.installedProjectSourceVersion;
    final reboot = resolveRebootStatus(
      state['reboot_required'] == true,
      installedRelease,
      activeRelease,
      _nullableString(state['last_check_status']),
    );
    final candidate = _nullableString(checkState['candidate_source_version']);
    final candidateAlreadyInstalled =
        candidate != null && candidate == installedSourceVersion;
    final rootAvailableSource =
        _nullableString(state['available_source_version']);
    final rootHasCurrentCandidate = candidate != null &&
        rootAvailableSource != null &&
        candidate == rootAvailableSource;
    final rootStatus = reboot.lastCheckStatus;
    final rootCandidateStatus = {
      'update-available',
      'package-manager-busy',
      'install-failed',
    }.contains(rootStatus);
    final useCheckState = !candidateAlreadyInstalled &&
        !reboot.rebootRequired &&
        !(rootHasCurrentCandidate && rootCandidateStatus);
    final checkStateReady = {
      'verified',
      'already-staged',
    }.contains(checkState['status']);
    final lastCheckStatus = useCheckState
        ? _nullableString(checkState['status']) ?? reboot.lastCheckStatus
        : reboot.lastCheckStatus;
    final checkFailureSource = useCheckState ? checkState : state;
    final updater = UpdateControllerStatus(
      controllerInstalled:
          timer.installed && checkServices.installed && helperInstalled,
      policy: policy,
      lastCheckStatus: lastCheckStatus,
      lastCheckedAt: useCheckState
          ? _nullableString(checkState['checked_at']) ??
              _nullableString(state['last_checked_at'])
          : _nullableString(state['last_checked_at']),
      availableSourceVersion:
          useCheckState && checkStateReady ? candidate : rootAvailableSource,
      availableKernelRelease: useCheckState && checkStateReady
          ? _nullableString(checkState['kernel_release'])
          : _nullableString(state['available_kernel_release']),
      installedSourceVersion: installedSourceVersion,
      installedKernelRelease: installedRelease,
      rebootRequired: reboot.rebootRequired,
      timerEnabled: timer.enabled,
      timerActive: timer.active,
      nextCheckAt: timer.nextCheckAt,
      checkServiceActive: checkServices.active,
      downloadedBytes: useCheckState
          ? _nullableNonNegativeInt(checkState['downloaded_bytes'])
          : null,
      totalBytes: useCheckState
          ? _nullableNonNegativeInt(checkState['total_bytes'])
          : null,
      currentAsset:
          useCheckState ? _nullableString(checkState['current_asset']) : null,
      checkFailedPhase: lastCheckStatus == 'check-failed'
          ? parseCheckFailedPhase(checkFailureSource['failed_phase'])
          : null,
      lastCheckError: lastCheckStatus == 'check-failed'
          ? _nullableBoundedString(checkFailureSource['error'])
          : null,
      projectKernelHistory: await _readProjectKernelHistory(warnings),
    );
    const diagnosticOrder = [
      'running-kernel',
      'secure-boot',
      'kernel-lockdown',
      'luks-root',
      'memory-info',
      'swap-list',
      'installed-kernels',
    ];
    diagnostics.sort((left, right) => diagnosticOrder
        .indexOf(left.id)
        .compareTo(diagnosticOrder.indexOf(right.id)));
    warnings.sort();
    return SystemSnapshot(
      collectedAt: DateTime.now().toUtc(),
      systemStatus: SystemStatus(
        deviceName: Platform.localHostname,
        ubuntuVersion: ubuntuVersion,
        secureBoot: secureBoot,
        lockdown: lockdown,
        luks: luks,
        tpmConfigured: tpmConfigured,
        hibernatePartition: hibernatePartition,
        grubUpdated: grubUpdated,
        projectHeadersInstalled: installed.projectHeadersInstalled,
      ),
      kernels: installed.kernels,
      preflightDiagnostics: diagnostics,
      updater: updater,
      warnings: warnings,
    );
  }

  Future<String> _readOperatingSystem() async {
    final source = await File('/etc/os-release').readAsString();
    for (final line in source.split('\n')) {
      if (!line.startsWith('PRETTY_NAME=')) continue;
      var value = line.substring('PRETTY_NAME='.length);
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value
            .substring(1, value.length - 1)
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', r'\');
      }
      if (value.isNotEmpty) return value;
    }
    throw const FormatException('/etc/os-release has no PRETTY_NAME');
  }

  Future<bool> _readSecureBoot(List<PreflightDiagnostic> diagnostics) async {
    final output = (await _runChecked(
      '/usr/bin/mokutil',
      const ['--sb-state'],
      diagnosticId: 'secure-boot',
      diagnostics: diagnostics,
    ))
        .toLowerCase();
    if (output.contains('secureboot enabled')) return true;
    if (output.contains('secureboot disabled')) return false;
    throw FormatException('Unexpected mokutil output: ${output.trim()}');
  }

  Future<bool> _readLockdown(List<PreflightDiagnostic> diagnostics) async {
    final output = await _readDiagnosticFile(
      '/sys/kernel/security/lockdown',
      'kernel-lockdown',
      diagnostics,
    );
    if (RegExp(r'\[(integrity|confidentiality)\]').hasMatch(output)) {
      return true;
    }
    if (output.contains('[none]')) return false;
    throw FormatException('Unexpected lockdown state: ${output.trim()}');
  }

  Future<bool> _readLuksState(List<PreflightDiagnostic> diagnostics) async {
    final output = await _runChecked(
      '/usr/bin/lsblk',
      const ['--json', '--output', 'NAME,TYPE,FSTYPE,MOUNTPOINTS'],
      diagnosticId: 'luks-root',
      diagnostics: diagnostics,
    );
    final decoded = jsonDecode(output);
    if (decoded is! Map<String, dynamic> ||
        decoded['blockdevices'] is! List<dynamic>) {
      throw const FormatException('lsblk returned an invalid device tree');
    }
    return (decoded['blockdevices'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .any((device) => _rootUsesLuks(device));
  }

  bool _rootUsesLuks(
    Map<String, dynamic> device, [
    bool encryptedAncestor = false,
  ]) {
    final encrypted = encryptedAncestor ||
        device['type'] == 'crypt' ||
        device['fstype'] == 'crypto_LUKS';
    final mountpoints = device['mountpoints'];
    if (mountpoints is List<dynamic> && mountpoints.contains('/')) {
      return encrypted;
    }
    final children = device['children'];
    return children is List<dynamic> &&
        children
            .whereType<Map<String, dynamic>>()
            .any((child) => _rootUsesLuks(child, encrypted));
  }

  Future<bool> _readTpmBinding() async {
    final source = await File('/etc/crypttab').readAsString();
    for (final line in source.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length >= 4 &&
          fields[3]
              .split(',')
              .any((option) => option.startsWith('tpm2-device='))) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _readHibernateCapacity(
    List<PreflightDiagnostic> diagnostics,
  ) async {
    final meminfo = await _readDiagnosticFile(
      '/proc/meminfo',
      'memory-info',
      diagnostics,
    );
    final swaps = await _readDiagnosticFile(
      '/proc/swaps',
      'swap-list',
      diagnostics,
    );
    final memory = RegExp(r'^MemTotal:\s+(\d+)\s+kB$', multiLine: true)
        .firstMatch(meminfo);
    if (memory == null) {
      throw const FormatException('MemTotal is missing from /proc/meminfo');
    }
    var diskSwapKiB = 0;
    for (final line in swaps.split('\n').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 3 || fields[0].startsWith('/dev/zram')) continue;
      diskSwapKiB += int.tryParse(fields[2]) ?? 0;
    }
    return diskSwapKiB >= int.parse(memory.group(1)!);
  }

  Future<bool> _readGrubIntegration() async {
    final file = File('/etc/grub.d/11_s4lockdown_resume');
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || (stat.mode & 0x49) == 0) {
      return false;
    }
    return (await file.readAsString()).contains("--id 's4lockdown-resume'");
  }

  Future<UpdatePolicy> _readUpdatePolicy() async {
    final source = await File('/etc/s4lockdown-update.conf').readAsString();
    final match = RegExp(
      r'^POLICY=(manual|check-and-notify|automatic-install)$',
      multiLine: true,
    ).firstMatch(source);
    if (match == null) {
      throw const FormatException('Updater configuration has no POLICY value');
    }
    return UpdatePolicyWireValue.parse(match.group(1)!);
  }

  Future<int> _readProjectKernelHistory(List<String> warnings) async {
    try {
      final source = await File('/etc/s4lockdown-update.conf').readAsString();
      final match = RegExp(r'^PROJECT_KERNEL_HISTORY=([123])$', multiLine: true)
          .firstMatch(source);
      return match == null ? 2 : int.parse(match.group(1)!);
    } on Object catch (error) {
      warnings.add('Project kernel history: $error');
      return 2;
    }
  }

  Future<_TimerStatus> _readTimerStatus() async {
    final output = await _runChecked(
      '/usr/bin/systemctl',
      const [
        'show',
        's4lockdown-update.timer',
        '--property=LoadState,ActiveState,UnitFileState,NextElapseUSecRealtime',
        '--no-pager',
      ],
    );
    final values = _parseProperties(output);
    return _TimerStatus(
      installed: values['LoadState'] == 'loaded',
      enabled: values['UnitFileState'] == 'enabled',
      active: values['ActiveState'] == 'active',
      nextCheckAt: _emptyToNull(values['NextElapseUSecRealtime']),
    );
  }

  Future<_ServiceStatus> _readCheckServicesStatus() async {
    final statuses = await Future.wait([
      _readServiceStatus('s4lockdown-update-manager-check.service'),
      _readServiceStatus('s4lockdown-update-check.service'),
    ]);
    return _ServiceStatus(
      installed: statuses.every((status) => status.installed),
      active: statuses.any((status) => status.active),
    );
  }

  Future<_ServiceStatus> _readServiceStatus(String unit) async {
    final output = await _runChecked(
      '/usr/bin/systemctl',
      [
        'show',
        unit,
        '--property=LoadState,ActiveState',
        '--no-pager',
      ],
    );
    final values = _parseProperties(output);
    return _ServiceStatus(
      installed: values['LoadState'] == 'loaded',
      active: values['ActiveState'] == 'active' ||
          values['ActiveState'] == 'activating',
    );
  }

  Future<_InstalledKernelState> _readInstalledKernels(
    String activeRelease,
    Map<String, dynamic> state,
    List<PreflightDiagnostic> diagnostics,
  ) async {
    final output = await _runChecked(
      '/usr/bin/dpkg-query',
      const [
        '-W',
        r'-f=${binary:Package}\t${db:Status-Abbrev}\t${Version}\n',
        'linux-image-*',
        'linux-headers-*',
      ],
      diagnosticId: 'installed-kernels',
      diagnostics: diagnostics,
    );
    final kernels = <KernelInfo>[];
    final headers = <String>{};
    final imagePackageVersions = <String, String>{};
    for (final line in output.split('\n')) {
      final fields = line.split('\t');
      if (fields.length < 2) continue;
      final header = RegExp(r'^linux-headers-([0-9].*)$').firstMatch(fields[0]);
      if (header != null && fields[1] == 'ii ') {
        headers.add(header.group(1)!);
        continue;
      }
      final image = RegExp(r'^linux-image-([0-9].*)$').firstMatch(fields[0]);
      if (image == null || fields[1] != 'ii ') continue;
      final release = image.group(1)!;
      if (fields.length >= 3) imagePackageVersions[release] = fields[2];
      kernels.add(KernelInfo(
        id: 'installed-$release',
        version: release,
        project: release.contains('s4lockdown'),
        status: release == activeRelease
            ? KernelStatus.active
            : KernelStatus.installed,
      ));
    }
    if (!kernels.any((kernel) => kernel.version == activeRelease)) {
      kernels.add(KernelInfo(
        id: 'running-$activeRelease',
        version: activeRelease,
        project: activeRelease.contains('s4lockdown'),
        status: KernelStatus.active,
      ));
    }
    final available = _nullableString(state['available_kernel_release']);
    if (available != null &&
        !kernels.any((kernel) => kernel.version == available)) {
      kernels.add(KernelInfo(
        id: 'available-$available',
        version: available,
        project: true,
        status: KernelStatus.available,
        releaseDate: _datePrefix(_nullableString(state['last_checked_at'])),
      ));
    }
    const statusOrder = {
      KernelStatus.active: 0,
      KernelStatus.installed: 1,
      KernelStatus.available: 2,
    };
    kernels.sort((left, right) {
      final byStatus =
          statusOrder[left.status]!.compareTo(statusOrder[right.status]!);
      if (byStatus != 0) return byStatus;
      if (left.project != right.project) return left.project ? -1 : 1;
      return right.version.compareTo(left.version);
    });
    final inferred = inferInstalledProjectKernel(
      kernels: kernels,
      headerReleases: headers,
      imagePackageVersions: imagePackageVersions,
      activeRelease: activeRelease,
      recordedRelease: _nullableString(state['installed_kernel_release']),
    );
    return _InstalledKernelState(
      kernels: kernels,
      projectHeadersInstalled: inferred.release != null,
      installedProjectRelease: inferred.release,
      installedProjectSourceVersion: inferred.sourceVersion,
    );
  }

  Future<bool> _isSecureHelper() async {
    final result = await _commands.run(
      '/usr/bin/stat',
      const ['--format=%F\t%u\t%a', '--', _helperPath],
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        result.stderr.trim().isEmpty
            ? 'Unable to inspect helper'
            : result.stderr.trim(),
        _helperPath,
        OSError('', result.exitCode),
      );
    }
    final fields = result.stdout.trim().split('\t');
    if (fields.length != 3 || fields[0] != 'regular file' || fields[1] != '0') {
      return false;
    }
    final mode = int.tryParse(fields[2], radix: 8);
    return mode != null && (mode & 0x12) == 0 && (mode & 0x49) != 0;
  }

  Future<String> _runChecked(
    String executable,
    List<String> arguments, {
    String? diagnosticId,
    List<PreflightDiagnostic>? diagnostics,
  }) async {
    CommandResult result;
    try {
      result = await _commands.run(executable, arguments);
    } on Object catch (error) {
      if (diagnosticId != null && diagnostics != null) {
        diagnostics.add(PreflightDiagnostic(
          id: diagnosticId,
          operation: 'execFile',
          source: executable,
          arguments: List.unmodifiable(arguments),
          stdout: '',
          stderr: '',
          error: error.toString(),
          exitCode: null,
        ));
      }
      rethrow;
    }
    if (diagnosticId != null && diagnostics != null) {
      diagnostics.add(PreflightDiagnostic(
        id: diagnosticId,
        operation: 'execFile',
        source: executable,
        arguments: List.unmodifiable(arguments),
        stdout: result.stdout,
        stderr: result.stderr,
        error: result.exitCode == 0
            ? null
            : '$executable exited with status ${result.exitCode}',
        exitCode: result.exitCode,
      ));
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        result.stderr.trim().isEmpty
            ? 'Exited with status ${result.exitCode}'
            : result.stderr.trim(),
        result.exitCode,
      );
    }
    return result.stdout;
  }

  Future<String> _readDiagnosticFile(
    String path,
    String id,
    List<PreflightDiagnostic> diagnostics,
  ) async {
    try {
      final output = await File(path).readAsString();
      diagnostics.add(PreflightDiagnostic(
        id: id,
        operation: 'readFile',
        source: path,
        arguments: const [],
        stdout: output,
        stderr: '',
        error: null,
        exitCode: 0,
      ));
      return output;
    } on Object catch (error) {
      diagnostics.add(PreflightDiagnostic(
        id: id,
        operation: 'readFile',
        source: path,
        arguments: const [],
        stdout: '',
        stderr: '',
        error: error.toString(),
        exitCode: null,
      ));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _readJsonObject(String path) async {
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Expected a JSON object in $path');
    }
    return decoded;
  }

  Future<void> _writeProgress(SetupProgress progress) async {
    final content = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'checkpoint': progress.checkpoint?.wireValue,
      'completed': progress.completed,
    });
    await _writeAtomic(_progressPath, '$content\n', createParent: true);
  }

  Future<void> _writeAtomic(
    String path,
    String content, {
    required bool createParent,
  }) async {
    final separator = path.lastIndexOf('/');
    if (separator < 1) throw ArgumentError.value(path, 'path');
    final parent = path.substring(0, separator);
    if (createParent) {
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(parent).create(recursive: true);
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('Refusing a non-directory state parent: $parent');
      }
      final chmod = await _commands.run('/usr/bin/chmod', ['0700', parent]);
      if (chmod.exitCode != 0) {
        throw StateError('Unable to restrict state directory permissions');
      }
    }
    final temporary = '$path.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final file = File(temporary);
    await file.create(exclusive: true);
    try {
      final chmod = await _commands.run('/usr/bin/chmod', ['0600', temporary]);
      if (chmod.exitCode != 0) {
        throw StateError('Unable to restrict file permissions');
      }
      final handle = await file.open(mode: FileMode.writeOnly);
      try {
        await handle.writeString(content);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await file.rename(path);
    } on Object {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> _installAutostart() async {
    final gtkLaunch = await _commands.run(
      '/usr/bin/test',
      const ['-x', '/usr/bin/gtk-launch'],
    );
    if (gtkLaunch.exitCode != 0) {
      throw StateError('/usr/bin/gtk-launch is unavailable');
    }
    final existingType =
        await FileSystemEntity.type(_autostartPath, followLinks: false);
    if (existingType != FileSystemEntityType.notFound) {
      if (existingType != FileSystemEntityType.file) {
        throw StateError(
            'Refusing to replace a non-regular setup autostart entry');
      }
      final existing = await File(_autostartPath).readAsString();
      if (!existing.split('\n').contains(_autostartMarker)) {
        throw StateError(
          'Refusing to replace an autostart entry not created by the Manager',
        );
      }
    }
    final parent = Directory('$_configRoot/autostart');
    await parent.create(recursive: true);
    const content = '''[Desktop Entry]
Type=Application
Version=1.0
Name=Secure Hibernate Setup Resume
Exec=/usr/bin/gtk-launch $_appId
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
$_autostartMarker
''';
    await _writeAtomic(_autostartPath, content, createParent: false);
  }

  Future<void> _removeAutostart() async {
    final type =
        await FileSystemEntity.type(_autostartPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw StateError(
          'Refusing to remove a non-regular setup autostart entry');
    }
    final file = File(_autostartPath);
    final content = await file.readAsString();
    if (!content.split('\n').contains(_autostartMarker)) {
      throw StateError(
        'Refusing to remove an autostart entry not created by the Manager',
      );
    }
    await file.delete();
  }
}

ManagerActionResult parseManagerActionResponse(
  ManagerActionRequest request,
  String stdout,
) {
  final decoded = jsonDecode(stdout);
  if (decoded is! Map<String, dynamic> ||
      decoded['schemaVersion'] != 1 ||
      decoded['action'] != request.action.wireValue ||
      (decoded['status'] != 'success' && decoded['status'] != 'error') ||
      (decoded['error'] != null && decoded['error'] is! String) ||
      decoded['data'] is! Map<String, dynamic>) {
    throw const FormatException(
        'Privileged helper returned an invalid response');
  }
  final success = decoded['status'] == 'success';
  final error = decoded['error'];
  if ((success && error != null) ||
      (!success && (error is! String || error.isEmpty))) {
    throw const FormatException(
      'Privileged helper returned an inconsistent response status',
    );
  }
  final data = _parseActionData(decoded['data'] as Map<String, dynamic>);
  if (success) _requireSuccessData(request, data);
  return ManagerActionResult(
    action: request.action,
    status: success ? ManagerActionStatus.success : ManagerActionStatus.error,
    error: error is String
        ? error.substring(0, error.length.clamp(0, 4096))
        : null,
    data: data,
  );
}

ManagerActionData _parseActionData(Map<String, dynamic> value) {
  final mokStatus = value['mokStatus'];
  if (mokStatus != null &&
      mokStatus != 'enrolled' &&
      mokStatus != 'pending' &&
      mokStatus != 'not-pending') {
    throw const FormatException('Helper returned an invalid MOK status');
  }
  final fingerprint = _optionalPatternString(
    value,
    'fingerprintSha256',
    _fingerprintPattern,
    95,
  );
  final password = _optionalPatternString(
    value,
    'oneTimePassword',
    RegExp(r'^(?:[a-z]{3}[0-9]{5}|[A-Za-z0-9]{12})$'),
    12,
  );
  UpdatePolicy? policy;
  if (value['policy'] != null) {
    if (value['policy'] is! String) {
      throw const FormatException('Helper returned an invalid update policy');
    }
    policy = UpdatePolicyWireValue.parse(value['policy'] as String);
  }
  final removedRelease = _optionalPatternString(
    value,
    'removedRelease',
    _projectReleasePattern,
    256,
  );
  final sourceVersion = _optionalPatternString(
    value,
    'installedSourceVersion',
    _sourceVersionPattern,
    256,
  );
  final kernelRelease = _optionalPatternString(
    value,
    'installedKernelRelease',
    _projectReleasePattern,
    256,
  );
  final projectKernelHistory = value['projectKernelHistory'];
  if (projectKernelHistory != null &&
      (projectKernelHistory is! int ||
          projectKernelHistory < 1 ||
          projectKernelHistory > 3)) {
    throw const FormatException(
        'Helper returned an invalid project kernel history');
  }
  final removedPackages = _parseStringList(value['removedPackages'], 16);
  final tokenIds = _parseStringList(
    value['addedTokenIds'],
    32,
    pattern: RegExp(r'^\d+$'),
  );
  String? headerBackup;
  if (value.containsKey('headerBackup')) {
    final candidate = value['headerBackup'];
    if (candidate != null &&
        (candidate is! String ||
            !candidate.startsWith(
              '/var/lib/s4lockdown-update/luks-header-backups/',
            ) ||
            candidate.length > 512)) {
      throw const FormatException(
          'Helper returned an invalid header backup path');
    }
    headerBackup = candidate as String?;
  }
  bool? checkedBool(String key) {
    if (!value.containsKey(key)) return null;
    final candidate = value[key];
    if (candidate is! bool) {
      throw FormatException('Helper returned an invalid $key');
    }
    return candidate;
  }

  final tokens = <ManagerTokenResult>[];
  if (value['tokens'] != null) {
    final raw = value['tokens'];
    if (raw is! List<dynamic> || raw.length > 32) {
      throw const FormatException('Helper returned invalid TPM results');
    }
    for (final item in raw) {
      if (item is! Map<String, dynamic> ||
          item['tokenId'] is! String ||
          !RegExp(r'^\d+$').hasMatch(item['tokenId'] as String) ||
          item['passed'] is! bool) {
        throw const FormatException(
            'Helper returned an invalid TPM token result');
      }
      tokens.add(ManagerTokenResult(
        tokenId: item['tokenId'] as String,
        passed: item['passed'] as bool,
      ));
    }
  }
  final recovery = value['passwordRecovery'];
  if (recovery != null && recovery != 'verified') {
    throw const FormatException(
        'Helper returned an invalid password recovery result');
  }
  final swapPath = value['swapPath'];
  if (swapPath != null && swapPath != '/swap.img') {
    throw const FormatException('Helper returned an invalid managed swap path');
  }
  final swapSizeBytes = value['swapSizeBytes'];
  if (swapSizeBytes != null &&
      (swapSizeBytes is! int ||
          swapSizeBytes <= 0 ||
          swapSizeBytes > 1024 * 1024 * 1024 * 1024)) {
    throw const FormatException('Helper returned an invalid managed swap size');
  }
  return ManagerActionData(
    mokStatus: mokStatus as String?,
    fingerprintSha256: fingerprint,
    oneTimePassword: password,
    policy: policy,
    projectKernelHistory: projectKernelHistory as int?,
    removedRelease: removedRelease,
    removedPackages: removedPackages,
    installedSourceVersion: sourceVersion,
    installedKernelRelease: kernelRelease,
    addedTokenIds: tokenIds,
    headerBackup: headerBackup,
    crypttabChanged: checkedBool('crypttabChanged'),
    alreadyConfigured: checkedBool('alreadyConfigured'),
    tokens: tokens,
    passwordRecovery: recovery as String?,
    swapPath: swapPath as String?,
    swapSizeBytes: swapSizeBytes as int?,
  );
}

void _requireSuccessData(
  ManagerActionRequest request,
  ManagerActionData data,
) {
  final tokenVerified = data.tokens.any((token) => token.passed);
  switch (request.action) {
    case ManagerActionType.prepareMok:
      if (data.fingerprintSha256 != _projectFingerprint ||
          (data.mokStatus != 'enrolled' &&
              !(data.mokStatus == 'pending' && data.oneTimePassword != null))) {
        throw const FormatException(
          'Helper returned an invalid project MOK result',
        );
      }
    case ManagerActionType.inspectMok:
      if (data.fingerprintSha256 != _projectFingerprint ||
          (data.mokStatus != 'enrolled' &&
              data.mokStatus != 'not-pending' &&
              !(data.mokStatus == 'pending' && data.oneTimePassword != null))) {
        throw const FormatException(
          'Helper returned an invalid project MOK inspection result',
        );
      }
    case ManagerActionType.cancelMok:
      if (data.mokStatus != 'not-pending') {
        throw const FormatException(
          'Helper returned an incomplete MOK cancellation result',
        );
      }
    case ManagerActionType.setPolicy:
      if (data.policy != request.policy) {
        throw const FormatException(
          'Helper did not confirm the requested update policy',
        );
      }
    case ManagerActionType.setKernelRetention:
      if (data.projectKernelHistory != request.projectKernelHistory) {
        throw const FormatException(
          'Helper did not confirm the requested project kernel history',
        );
      }
    case ManagerActionType.removeKernel:
      if (data.removedRelease != request.release ||
          data.removedPackages.isEmpty) {
        throw const FormatException(
          'Helper returned an incomplete kernel removal result',
        );
      }
    case ManagerActionType.installUpdate:
      if (data.installedSourceVersion == null ||
          data.installedKernelRelease == null) {
        throw const FormatException(
          'Helper did not confirm the installed kernel version',
        );
      }
    case ManagerActionType.verifyTpm:
      if (!tokenVerified) {
        throw const FormatException(
          'Helper did not confirm a working TPM token',
        );
      }
    case ManagerActionType.verifyRecovery:
      if (data.passwordRecovery != 'verified') {
        throw const FormatException(
          'Helper did not confirm password recovery',
        );
      }
    case ManagerActionType.enrollTpm:
      if (!tokenVerified || data.passwordRecovery != 'verified') {
        throw const FormatException(
          'Helper did not confirm TPM unlock and password recovery',
        );
      }
    case ManagerActionType.repairSwap:
      if (data.swapPath != '/swap.img' || data.swapSizeBytes == null) {
        throw const FormatException(
          'Helper did not confirm the repaired swap file',
        );
      }
    case ManagerActionType.startCheck:
    case ManagerActionType.pauseCheck:
    case ManagerActionType.resumeCheck:
      break;
  }
}

void assertSetupCanComplete(
  SystemSnapshot snapshot,
  bool requireTpm, {
  required bool passwordRecoveryVerified,
  required bool tpmUnlockVerified,
}) {
  final target = snapshot.updater.installedKernelRelease;
  final active = snapshot.kernels
      .where((kernel) => kernel.status == KernelStatus.active)
      .firstOrNull;
  final officialFallback = snapshot.kernels.any(
    (kernel) => !kernel.project && kernel.status != KernelStatus.available,
  );
  if (target == null ||
      active == null ||
      !active.project ||
      active.version != target) {
    throw StateError(
      'Setup completion requires the installed project kernel to be running',
    );
  }
  final status = snapshot.systemStatus;
  if (!status.secureBoot || !status.lockdown) {
    throw StateError(
      'Setup completion requires Secure Boot and Kernel Lockdown',
    );
  }
  if (!status.hibernatePartition) {
    throw StateError(
      'Setup completion requires sufficient disk-backed swap',
    );
  }
  if (!status.projectHeadersInstalled || !status.grubUpdated) {
    throw StateError(
      'Setup completion requires matching headers and GRUB integration',
    );
  }
  if (!snapshot.updater.controllerInstalled || !officialFallback) {
    throw StateError(
      'Setup completion requires the updater and an official Ubuntu fallback kernel',
    );
  }
  if (status.luks && !passwordRecoveryVerified) {
    throw StateError(
      'Setup completion requires a password recovery test in this application session',
    );
  }
  if (requireTpm && !status.luks) {
    throw StateError('TPM automatic unlock requires a LUKS root volume');
  }
  if (requireTpm && (!tpmUnlockVerified || !status.tpmConfigured)) {
    throw StateError(
      'Setup completion requires a working TPM token and initramfs binding',
    );
  }
}

void _validateActionRequest(ManagerActionRequest request) {
  final passwordAction = request.action == ManagerActionType.enrollTpm ||
      request.action == ManagerActionType.verifyRecovery;
  final password = request.recoveryPassword;
  if (passwordAction) {
    if (password == null ||
        password.isEmpty ||
        password.length > 4096 ||
        password.contains(0)) {
      throw ArgumentError('Manager LUKS password request is invalid');
    }
  } else if (password != null) {
    throw ArgumentError('Manager action contains an unsupported password');
  }
  if (request.action == ManagerActionType.setPolicy) {
    if (request.policy == null ||
        request.release != null ||
        request.projectKernelHistory != null) {
      throw ArgumentError('Manager policy request is invalid');
    }
  } else if (request.action == ManagerActionType.setKernelRetention) {
    if (request.projectKernelHistory == null ||
        request.projectKernelHistory! < 1 ||
        request.projectKernelHistory! > 3 ||
        request.policy != null ||
        request.release != null) {
      throw ArgumentError('Manager kernel retention request is invalid');
    }
  } else if (request.action == ManagerActionType.removeKernel) {
    if (request.policy != null ||
        request.release == null ||
        !_projectReleasePattern.hasMatch(request.release!)) {
      throw ArgumentError('Manager kernel removal request is invalid');
    }
  } else if (request.policy != null ||
      request.release != null ||
      request.projectKernelHistory != null) {
    throw ArgumentError('Manager action contains unsupported fields');
  }
}

ManagerActionResult _actionError(
  ManagerActionRequest request,
  String error,
) =>
    ManagerActionResult(
      action: request.action,
      status: ManagerActionStatus.error,
      error: error,
      data: const ManagerActionData(),
    );

String? _optionalPatternString(
  Map<String, dynamic> data,
  String key,
  RegExp pattern,
  int maximumLength,
) {
  if (!data.containsKey(key)) return null;
  final value = data[key];
  if (value is! String ||
      value.length > maximumLength ||
      !pattern.hasMatch(value)) {
    throw FormatException('Helper returned an invalid $key');
  }
  return value;
}

List<String> _parseStringList(
  Object? value,
  int maximumLength, {
  RegExp? pattern,
}) {
  if (value == null) return const [];
  if (value is! List<dynamic> || value.length > maximumLength) {
    throw const FormatException('Helper returned an invalid string list');
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String ||
        item.length > 256 ||
        (pattern != null && !pattern.hasMatch(item))) {
      throw const FormatException('Helper returned an invalid string list');
    }
    result.add(item);
  }
  return result;
}

class RebootStatus {
  const RebootStatus({required this.rebootRequired, this.lastCheckStatus});

  final bool rebootRequired;
  final String? lastCheckStatus;
}

RebootStatus resolveRebootStatus(
  bool recordedRebootRequired,
  String? installedKernelRelease,
  String activeRelease,
  String? lastCheckStatus,
) {
  final rebootRequired =
      recordedRebootRequired && installedKernelRelease != activeRelease;
  return RebootStatus(
    rebootRequired: rebootRequired,
    lastCheckStatus:
        !rebootRequired && lastCheckStatus == 'installed-reboot-required'
            ? 'current'
            : lastCheckStatus,
  );
}

Future<T> _capture<T>(
  String label,
  Future<T> Function() operation,
  T fallback,
  List<String> warnings,
) async {
  try {
    return await operation();
  } on Object catch (error) {
    warnings.add('$label: $error');
    return fallback;
  }
}

Map<String, String> _parseProperties(String source) {
  final result = <String, String>{};
  for (final line in source.trim().split('\n')) {
    final separator = line.indexOf('=');
    if (separator < 0) continue;
    result[line.substring(0, separator)] = line.substring(separator + 1);
  }
  return result;
}

String? _nullableString(Object? value) => value is String ? value : null;

String? _nullableBoundedString(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value.substring(0, value.length.clamp(0, 4096));
}

String? parseCheckFailedPhase(Object? value) {
  if (value is! String) return null;
  const phases = {
    'indexing',
    'downloading',
    'verifying-manifest',
    'verifying-packages',
    'authorizing-version',
  };
  return phases.contains(value) ? value : null;
}

({String? release, String? sourceVersion}) inferInstalledProjectKernel({
  required Iterable<KernelInfo> kernels,
  required Set<String> headerReleases,
  required Map<String, String> imagePackageVersions,
  required String activeRelease,
  String? recordedRelease,
}) {
  final releases = kernels
      .where((kernel) =>
          kernel.project &&
          kernel.status != KernelStatus.available &&
          headerReleases.contains(kernel.version))
      .map((kernel) => kernel.version)
      .toList();
  final release = recordedRelease != null
      ? releases.contains(recordedRelease)
          ? recordedRelease
          : null
      : releases.where((value) => value == activeRelease).firstOrNull ??
          releases.firstOrNull;
  return (
    release: release,
    sourceVersion: release == null
        ? null
        : _projectSourceVersion(imagePackageVersions[release]),
  );
}

String? _projectSourceVersion(String? packageVersion) {
  if (packageVersion == null) return null;
  final marker = packageVersion.lastIndexOf('+ubuntu');
  if (marker < 0) return null;
  final sourceVersion = packageVersion.substring(marker + '+ubuntu'.length);
  return _sourceVersionPattern.hasMatch(sourceVersion) ? sourceVersion : null;
}

String? _emptyToNull(String? value) =>
    value == null || value.isEmpty ? null : value;
String? _datePrefix(String? value) =>
    value?.substring(0, value.length.clamp(0, 10));
int? _nullableNonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

class _TimerStatus {
  const _TimerStatus({
    this.installed = false,
    this.enabled = false,
    this.active = false,
    this.nextCheckAt,
  });

  final bool installed;
  final bool enabled;
  final bool active;
  final String? nextCheckAt;
}

class _ServiceStatus {
  const _ServiceStatus({this.installed = false, this.active = false});

  final bool installed;
  final bool active;
}

class _InstalledKernelState {
  const _InstalledKernelState({
    required this.kernels,
    required this.projectHeadersInstalled,
    this.installedProjectRelease,
    this.installedProjectSourceVersion,
  });

  final List<KernelInfo> kernels;
  final bool projectHeadersInstalled;
  final String? installedProjectRelease;
  final String? installedProjectSourceVersion;
}

Map<String, Object?> _snapshotToJson(SystemSnapshot snapshot) => {
      'schemaVersion': 5,
      'collectedAt': snapshot.collectedAt.toIso8601String(),
      'systemStatus': {
        'deviceName': snapshot.systemStatus.deviceName,
        'ubuntuVersion': snapshot.systemStatus.ubuntuVersion,
        'secureBoot': snapshot.systemStatus.secureBoot,
        'lockdown': snapshot.systemStatus.lockdown,
        'luks': snapshot.systemStatus.luks,
        'tpmConfigured': snapshot.systemStatus.tpmConfigured,
        'hibernatePartition': snapshot.systemStatus.hibernatePartition,
        'grubUpdated': snapshot.systemStatus.grubUpdated,
        'projectHeadersInstalled':
            snapshot.systemStatus.projectHeadersInstalled,
        'projectCertEnrolled': null,
      },
      'kernels': snapshot.kernels
          .map((kernel) => {
                'id': kernel.id,
                'version': kernel.version,
                'type': kernel.project ? 'project' : 'official',
                'status': kernel.status.name,
                if (kernel.releaseDate != null)
                  'releaseDate': kernel.releaseDate,
              })
          .toList(),
      'preflightDiagnostics': snapshot.preflightDiagnostics
          .map((diagnostic) => {
                'id': diagnostic.id,
                'operation': diagnostic.operation,
                'source': diagnostic.source,
                'arguments': diagnostic.arguments,
                'stdout': diagnostic.stdout,
                'stderr': diagnostic.stderr,
                'error': diagnostic.error,
                'exitCode': diagnostic.exitCode,
              })
          .toList(),
      'updater': {
        'controllerInstalled': snapshot.updater.controllerInstalled,
        'policy': snapshot.updater.policy.wireValue,
        'lastCheckStatus': snapshot.updater.lastCheckStatus,
        'lastCheckedAt': snapshot.updater.lastCheckedAt,
        'availableSourceVersion': snapshot.updater.availableSourceVersion,
        'availableKernelRelease': snapshot.updater.availableKernelRelease,
        'installedSourceVersion': snapshot.updater.installedSourceVersion,
        'installedKernelRelease': snapshot.updater.installedKernelRelease,
        'rebootRequired': snapshot.updater.rebootRequired,
        'timerEnabled': snapshot.updater.timerEnabled,
        'timerActive': snapshot.updater.timerActive,
        'nextCheckAt': snapshot.updater.nextCheckAt,
        'checkServiceActive': snapshot.updater.checkServiceActive,
        'downloadedBytes': snapshot.updater.downloadedBytes,
        'totalBytes': snapshot.updater.totalBytes,
        'currentAsset': snapshot.updater.currentAsset,
        'checkFailedPhase': snapshot.updater.checkFailedPhase,
        'lastCheckError': snapshot.updater.lastCheckError,
        'projectKernelHistory': snapshot.updater.projectKernelHistory,
      },
      'warnings': snapshot.warnings,
    };

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
