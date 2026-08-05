import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_hibernate_manager/src/backend.dart';
import 'package:secure_hibernate_manager/src/native_backend.dart';
import 'package:secure_hibernate_manager/src/pages/installation_wizard.dart';

const _projectFingerprint =
    '5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:'
    'D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11';

String _helperResponse(
  ManagerActionType action, {
  String status = 'success',
  String? error,
  Map<String, Object?> data = const {},
}) =>
    jsonEncode({
      'schemaVersion': 1,
      'action': action.wireValue,
      'status': status,
      'error': error,
      'data': data,
    });

SystemSnapshot _completeSnapshot({
  bool secureBoot = true,
  bool lockdown = true,
  bool luks = true,
  bool tpmConfigured = true,
  bool officialFallback = true,
}) {
  const projectRelease = '7.0.12-28-hibernate';
  return SystemSnapshot(
    collectedAt: DateTime.utc(2026),
    systemStatus: SystemStatus(
      deviceName: 'vm',
      ubuntuVersion: 'Ubuntu',
      secureBoot: secureBoot,
      lockdown: lockdown,
      luks: luks,
      tpmConfigured: tpmConfigured,
      hibernatePartition: true,
      grubUpdated: true,
      projectHeadersInstalled: true,
    ),
    kernels: [
      const KernelInfo(
        id: 'project',
        version: projectRelease,
        project: true,
        status: KernelStatus.active,
      ),
      if (officialFallback)
        const KernelInfo(
          id: 'official',
          version: '7.0.0-28-generic',
          project: false,
          status: KernelStatus.installed,
        ),
    ],
    preflightDiagnostics: const [],
    updater: const UpdateControllerStatus(
      controllerInstalled: true,
      policy: UpdatePolicy.manual,
      lastCheckStatus: 'current',
      lastCheckedAt: null,
      availableSourceVersion: null,
      availableKernelRelease: null,
      installedSourceVersion: '7.0.0-28.28',
      installedKernelRelease: projectRelease,
      rebootRequired: false,
      timerEnabled: false,
      timerActive: false,
      nextCheckAt: null,
      checkServiceActive: false,
      downloadedBytes: null,
      totalBytes: null,
      currentAsset: null,
    ),
    warnings: const [],
  );
}

class _BlockingCommandRunner implements CommandRunner {
  final Completer<void> pkexecStarted = Completer<void>();
  final Completer<void> releasePkexec = Completer<void>();
  int pkexecCalls = 0;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    List<int>? stdinBytes,
  }) async {
    if (executable == '/usr/bin/stat') {
      return const CommandResult(
        exitCode: 0,
        stdout: 'regular file\t0\t755\n',
        stderr: '',
      );
    }
    if (executable == '/usr/bin/pkexec') {
      pkexecCalls += 1;
      if (!pkexecStarted.isCompleted) pkexecStarted.complete();
      await releasePkexec.future;
      return CommandResult(
        exitCode: 0,
        stdout: _helperResponse(ManagerActionType.startCheck),
        stderr: '',
      );
    }
    throw StateError('Unexpected test command: $executable $arguments');
  }
}

class _DeniedCommandRunner implements CommandRunner {
  int pkexecCalls = 0;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    List<int>? stdinBytes,
  }) async {
    if (executable == '/usr/bin/stat') {
      return const CommandResult(
        exitCode: 0,
        stdout: 'regular file\t0\t755\n',
        stderr: '',
      );
    }
    if (executable == '/usr/bin/pkexec') {
      pkexecCalls += 1;
      return const CommandResult(
        exitCode: 126,
        stdout: '',
        stderr: 'Not authorized',
      );
    }
    throw StateError('Unexpected test command: $executable $arguments');
  }
}

class _StartupRefreshCommandRunner implements CommandRunner {
  int pkexecCalls = 0;
  List<String>? pkexecArguments;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    List<int>? stdinBytes,
  }) async {
    if (executable == '/usr/bin/stat') {
      return const CommandResult(
        exitCode: 0,
        stdout: 'regular file\t0\t755\n',
        stderr: '',
      );
    }
    if (executable == '/usr/bin/pkexec') {
      pkexecCalls += 1;
      pkexecArguments = arguments;
      return CommandResult(
        exitCode: 0,
        stdout: _helperResponse(
          ManagerActionType.startupRefresh,
          data: const {
            'mokStatus': 'enrolled',
            'fingerprintSha256': _projectFingerprint,
          },
        ),
        stderr: '',
      );
    }
    throw StateError('Unexpected test command: $executable $arguments');
  }
}

class _PasswordCommandRunner implements CommandRunner {
  List<String>? pkexecArguments;
  List<int>? pkexecStdin;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
    List<int>? stdinBytes,
  }) async {
    if (executable == '/usr/bin/stat') {
      return const CommandResult(
        exitCode: 0,
        stdout: 'regular file\t0\t755\n',
        stderr: '',
      );
    }
    if (executable == '/usr/bin/pkexec') {
      pkexecArguments = List.of(arguments);
      pkexecStdin = stdinBytes == null ? null : List.of(stdinBytes);
      return CommandResult(
        exitCode: 0,
        stdout: _helperResponse(
          ManagerActionType.enrollTpm,
          data: const {
            'passwordRecovery': 'verified',
            'tokens': [
              {'tokenId': '0', 'passed': true},
            ],
          },
        ),
        stderr: '',
      );
    }
    throw StateError('Unexpected test command: $executable $arguments');
  }
}

void main() {
  test('uses a terminal updater state observed after the check service exits',
      () {
    final running = <String, dynamic>{
      'status': 'verifying-packages',
      'checked_at': '2026-08-03T06:32:50Z',
    };
    final verified = <String, dynamic>{
      'status': 'verified',
      'checked_at': '2026-08-03T06:32:54Z',
    };
    final failed = <String, dynamic>{
      'status': 'check-failed',
      'checked_at': '2026-08-03T06:32:54Z',
      'failed_phase': 'verifying-packages',
    };

    expect(
      authoritativeUpdaterCheckState(
        running,
        checkServiceActive: false,
        refreshed: verified,
      ),
      same(verified),
    );
    expect(
      authoritativeUpdaterCheckState(
        running,
        checkServiceActive: false,
        refreshed: failed,
      ),
      same(failed),
    );
  });

  test('does not invent a terminal updater state', () {
    final running = <String, dynamic>{'status': 'verifying-packages'};
    final stillRunning = <String, dynamic>{'status': 'authorizing-version'};

    expect(
      authoritativeUpdaterCheckState(
        running,
        checkServiceActive: true,
        refreshed: <String, dynamic>{'status': 'verified'},
      ),
      same(running),
    );
    expect(
      authoritativeUpdaterCheckState(
        running,
        checkServiceActive: false,
        refreshed: stillRunning,
      ),
      same(running),
    );
    expect(
      authoritativeUpdaterCheckState(
        running,
        checkServiceActive: false,
        refreshed: <String, dynamic>{},
      ),
      same(running),
    );
  });

  test('accepts only fixed updater check failure phases', () {
    for (final phase in const [
      'indexing',
      'downloading',
      'verifying-manifest',
      'verifying-packages',
      'authorizing-version',
    ]) {
      expect(parseCheckFailedPhase(phase), phase);
    }
    expect(parseCheckFailedPhase('installing-packages'), isNull);
    expect(parseCheckFailedPhase(1), isNull);
  });

  test('installation progress accepts fixed milestones and retained failure',
      () {
    final verifying = parseInstallProgressState({
      'install_phase': 'verifying-packages',
      'install_progress': 70,
    });
    expect(verifying.phase, InstallPhase.verifyingPackages);
    expect(verifying.progress, 70);

    final recoveredDownload = parseInstallProgressState({
      'install_phase': 'downloading-release',
      'install_progress': 31,
      'install_updated_at': '2026-08-03T04:00:00.123456Z',
    });
    expect(recoveredDownload.phase, InstallPhase.downloadingRelease);
    expect(recoveredDownload.progress, 31);
    expect(recoveredDownload.updatedAt, '2026-08-03T04:00:00.123456Z');

    final failed = parseInstallProgressState({
      'install_phase': 'failed',
      'install_progress': 65,
    });
    expect(failed.phase, InstallPhase.failed);
    expect(failed.progress, 65);
  });

  test('installation progress rejects inconsistent state', () {
    expect(
      () => parseInstallProgressState({
        'install_phase': 'installing-packages',
        'install_progress': 35,
      }),
      throwsFormatException,
    );
  });

  test('installation progress waits for a state write from this action', () {
    const stale = InstallProgress(
      phase: InstallPhase.failed,
      progress: 78,
      updatedAt: '2026-08-03T03:00:00Z',
    );
    expect(
      installProgressBelongsToCurrentAction(
        baselineUpdatedAt: stale.updatedAt,
        alreadyObserved: false,
        observed: stale,
      ),
      isFalse,
    );

    const started = InstallProgress(
      phase: InstallPhase.preparing,
      progress: 5,
      updatedAt: '2026-08-03T03:00:00.500000Z',
    );
    expect(
      installProgressBelongsToCurrentAction(
        baselineUpdatedAt: stale.updatedAt,
        alreadyObserved: false,
        observed: started,
      ),
      isTrue,
    );
  });

  test('installation progress targets the existing component rows', () {
    expect(installProgressTargetsProjectKernel(InstallPhase.preparing), isTrue);
    expect(
      installProgressTargetsProjectKernel(InstallPhase.verifyingPackages),
      isTrue,
    );
    expect(
      installProgressTargetsProjectKernel(InstallPhase.installingPackages),
      isTrue,
    );
    expect(
      installProgressTargetsSystemConfiguration(
        InstallPhase.configuringSystem,
      ),
      isTrue,
    );
    expect(
      installFailureTargetsSystemConfiguration(const InstallProgress(
        phase: InstallPhase.failed,
        progress: 90,
      )),
      isTrue,
    );
    expect(
      installFailureTargetsSystemConfiguration(const InstallProgress(
        phase: InstallPhase.failed,
        progress: 78,
      )),
      isFalse,
    );
  });

  test('infers a legacy installed project kernel from paired packages', () {
    const active = '7.0.12-ubuntu28-s4lockdown';
    final inferred = inferInstalledProjectKernel(
      kernels: const [
        KernelInfo(
          id: 'active',
          version: active,
          project: true,
          status: KernelStatus.active,
        ),
        KernelInfo(
          id: 'older',
          version: '7.0.12-s4lockdown',
          project: true,
          status: KernelStatus.installed,
        ),
      ],
      headerReleases: const {active, '7.0.12-s4lockdown'},
      imagePackageVersions: const {
        active: '1-ubuntu28-s4lockdown+ubuntu7.0.0-28.28',
        '7.0.12-s4lockdown': '1-s4lockdown+ubuntu7.0.0-28.28',
      },
      activeRelease: active,
    );

    expect(inferred.release, active);
    expect(inferred.sourceVersion, '7.0.0-28.28');
  });

  test('does not borrow headers from another recorded project kernel', () {
    const recorded = '7.0.13-29-hibernate';
    final inferred = inferInstalledProjectKernel(
      kernels: const [
        KernelInfo(
          id: 'target',
          version: recorded,
          project: true,
          status: KernelStatus.installed,
        ),
        KernelInfo(
          id: 'older',
          version: '7.0.12-28-hibernate',
          project: true,
          status: KernelStatus.active,
        ),
      ],
      headerReleases: const {'7.0.12-28-hibernate'},
      imagePackageVersions: const {
        recorded: '1-29-hibernate+ubuntu7.0.0-29.29',
      },
      activeRelease: '7.0.12-28-hibernate',
      recordedRelease: recorded,
    );

    expect(inferred.release, isNull);
    expect(inferred.sourceVersion, isNull);
  });

  group('privileged helper response', () {
    test('accepts only bounded project kernel retention responses', () {
      const request = ManagerActionRequest(
        ManagerActionType.setKernelRetention,
        projectKernelHistory: 2,
      );
      final result = parseManagerActionResponse(
        request,
        _helperResponse(
          request.action,
          data: const {'projectKernelHistory': 2},
        ),
      );
      expect(result.data.projectKernelHistory, 2);
      expect(
        () => parseManagerActionResponse(
          request,
          _helperResponse(
            request.action,
            data: const {'projectKernelHistory': 3},
          ),
        ),
        throwsFormatException,
      );
    });

    test('accepts only the pinned project MOK fingerprint', () {
      const request = ManagerActionRequest(ManagerActionType.inspectMok);
      final result = parseManagerActionResponse(
        request,
        _helperResponse(
          request.action,
          data: {
            'mokStatus': 'enrolled',
            'fingerprintSha256': _projectFingerprint,
            'stdout': 'must not cross the backend boundary',
          },
        ),
      );

      expect(result.status, ManagerActionStatus.success);
      expect(result.data.mokStatus, 'enrolled');
      expect(result.data.fingerprintSha256, _projectFingerprint);

      expect(
        () => parseManagerActionResponse(
          request,
          _helperResponse(
            request.action,
            data: {
              'mokStatus': 'enrolled',
              'fingerprintSha256': List.filled(32, 'AA').join(':'),
            },
          ),
        ),
        throwsFormatException,
      );
    });

    test('accepts new memorable and legacy pending MOK passwords', () {
      const request = ManagerActionRequest(ManagerActionType.prepareMok);
      for (final password in ['abc23456', 'Ab3Def4Gh5Jk']) {
        final result = parseManagerActionResponse(
          request,
          _helperResponse(
            request.action,
            data: {
              'mokStatus': 'pending',
              'fingerprintSha256': _projectFingerprint,
              'oneTimePassword': password,
            },
          ),
        );
        expect(result.data.oneTimePassword, password);
      }

      for (final password in ['abc2345', 'abcd2345', 'abc1234x']) {
        expect(
          () => parseManagerActionResponse(
            request,
            _helperResponse(
              request.action,
              data: {
                'mokStatus': 'pending',
                'fingerprintSha256': _projectFingerprint,
                'oneTimePassword': password,
              },
            ),
          ),
          throwsFormatException,
        );
      }
    });

    test('requires valid installed source and project-kernel releases', () {
      const request = ManagerActionRequest(ManagerActionType.installUpdate);
      final result = parseManagerActionResponse(
        request,
        _helperResponse(
          request.action,
          data: const {
            'installedSourceVersion': '7.0.0-29.29',
            'installedKernelRelease': '7.0.13-29-hibernate',
          },
        ),
      );
      expect(
        result.data.installedKernelRelease,
        '7.0.13-29-hibernate',
      );

      for (final data in <Map<String, Object?>>[
        const {},
        const {
          'installedSourceVersion': '7.0.0-29.29',
          'installedKernelRelease': '../../boot/vmlinuz',
        },
      ]) {
        expect(
          () => parseManagerActionResponse(
            request,
            _helperResponse(request.action, data: data),
          ),
          throwsFormatException,
        );
      }
    });

    test('requires positive TPM and password recovery evidence', () {
      const verifyTpm = ManagerActionRequest(ManagerActionType.verifyTpm);
      final verified = parseManagerActionResponse(
        verifyTpm,
        _helperResponse(
          verifyTpm.action,
          data: const {
            'alreadyConfigured': true,
            'tokens': [
              {'tokenId': '0', 'passed': true},
            ],
          },
        ),
      );
      expect(verified.data.tokens.single.passed, isTrue);

      final needsConfiguration = parseManagerActionResponse(
        verifyTpm,
        _helperResponse(
          verifyTpm.action,
          data: const {
            'alreadyConfigured': false,
            'tokens': [
              {'tokenId': '0', 'passed': false},
            ],
          },
        ),
      );
      expect(needsConfiguration.data.alreadyConfigured, isFalse);

      for (final data in <Map<String, Object?>>[
        const {},
        const {
          'alreadyConfigured': true,
          'tokens': [],
        },
        const {
          'alreadyConfigured': false,
          'tokens': [
            {'tokenId': '0', 'passed': true},
          ],
        },
      ]) {
        expect(
          () => parseManagerActionResponse(
            verifyTpm,
            _helperResponse(verifyTpm.action, data: data),
          ),
          throwsFormatException,
        );
      }

      const enrollTpm = ManagerActionRequest(ManagerActionType.enrollTpm);
      expect(
        () => parseManagerActionResponse(
          enrollTpm,
          _helperResponse(
            enrollTpm.action,
            data: const {
              'passwordRecovery': 'verified',
              'tokens': <Object?>[],
            },
          ),
        ),
        throwsFormatException,
      );
    });

    test('requires an exact successful managed swap result', () {
      const request = ManagerActionRequest(ManagerActionType.repairSwap);
      final result = parseManagerActionResponse(
        request,
        _helperResponse(
          request.action,
          data: const {
            'swapPath': '/swap.img',
            'swapSizeBytes': 8 * 1024 * 1024 * 1024,
          },
        ),
      );
      expect(result.data.swapPath, '/swap.img');
      expect(result.data.swapSizeBytes, 8 * 1024 * 1024 * 1024);

      for (final data in <Map<String, Object?>>[
        const {},
        const {'swapPath': '/tmp/swap.img', 'swapSizeBytes': 1024},
        const {'swapPath': '/swap.img', 'swapSizeBytes': -1},
      ]) {
        expect(
          () => parseManagerActionResponse(
            request,
            _helperResponse(request.action, data: data),
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects forged schema, action, and inconsistent status', () {
      const request = ManagerActionRequest(ManagerActionType.startCheck);
      for (final response in [
        '{"schemaVersion":2,"action":"start-check","status":"success",'
            '"error":null,"data":{}}',
        _helperResponse(ManagerActionType.pauseCheck),
        _helperResponse(
          request.action,
          status: 'error',
          error: null,
        ),
      ]) {
        expect(
          () => parseManagerActionResponse(request, response),
          throwsFormatException,
        );
      }
    });

    test('preserves explicit helper errors with a bounded message', () {
      const request = ManagerActionRequest(ManagerActionType.startCheck);
      final result = parseManagerActionResponse(
        request,
        _helperResponse(
          request.action,
          status: 'error',
          error: 'x' * 5000,
        ),
      );
      expect(result.status, ManagerActionStatus.error);
      expect(result.error, hasLength(4096));
    });
  });

  test('rejects a concurrent privileged action before a second pkexec',
      () async {
    final runner = _BlockingCommandRunner();
    final backend = NativeManagerBackend(
      commandRunner: runner,
      environment: const {'HOME': '/tmp/manager-native-backend-test'},
    );
    final first = backend.runManagerAction(
      const ManagerActionRequest(ManagerActionType.startCheck),
    );
    await runner.pkexecStarted.future;

    final second = await backend.runManagerAction(
      const ManagerActionRequest(ManagerActionType.pauseCheck),
    );
    expect(second.status, ManagerActionStatus.error);
    expect(second.error, contains('Another privileged Manager action'));
    expect(runner.pkexecCalls, 1);

    runner.releasePkexec.complete();
    expect((await first).status, ManagerActionStatus.success);
  });

  test('preserves Polkit cancellation as a visible cancelled result', () async {
    final runner = _DeniedCommandRunner();
    final backend = NativeManagerBackend(
      commandRunner: runner,
      environment: const {'HOME': '/tmp/manager-native-backend-test'},
    );

    final result = await backend.runManagerAction(
      const ManagerActionRequest(ManagerActionType.inspectMok),
    );

    expect(result.status, ManagerActionStatus.cancelled);
    expect(result.error, isNull);
    expect(runner.pkexecCalls, 1);
  });

  test('runs the fixed startup refresh through one pkexec call', () async {
    final runner = _StartupRefreshCommandRunner();
    final backend = NativeManagerBackend(
      commandRunner: runner,
      environment: const {'HOME': '/tmp/manager-native-backend-test'},
    );

    final result = await backend.runManagerAction(
      const ManagerActionRequest(ManagerActionType.startupRefresh),
    );

    expect(result.status, ManagerActionStatus.success);
    expect(
      projectMokInspectionFromActionResult(result).status,
      ProjectMokStatus.enrolled,
    );
    expect(runner.pkexecCalls, 1);
    expect(
      runner.pkexecArguments,
      const [
        '/usr/local/lib/s4lockdown-update/scripts/manager-helper.py',
        'startup-refresh',
      ],
    );
  });

  test('passes a LUKS password only through fixed helper stdin', () async {
    final runner = _PasswordCommandRunner();
    final backend = NativeManagerBackend(
      commandRunner: runner,
      environment: const {'HOME': '/tmp/manager-native-backend-test'},
    );
    final password = Uint8List.fromList(utf8.encode('test-secret'));

    final result = await backend.runManagerAction(
      ManagerActionRequest(
        ManagerActionType.enrollTpm,
        recoveryPassword: password,
      ),
    );

    expect(result.status, ManagerActionStatus.success);
    expect(
      runner.pkexecArguments,
      const [
        '/usr/local/lib/s4lockdown-update/scripts/manager-helper.py',
        'enroll-tpm',
        '--password-stdin',
      ],
    );
    expect(runner.pkexecArguments!.join(' '), isNot(contains('test-secret')));
    expect(runner.pkexecStdin, utf8.encode('test-secret'));
  });

  test('requires password bytes only for recovery password actions', () async {
    final backend = NativeManagerBackend(
      commandRunner: _DeniedCommandRunner(),
      environment: const {'HOME': '/tmp/manager-native-backend-test'},
    );

    await expectLater(
      backend.runManagerAction(
        const ManagerActionRequest(ManagerActionType.enrollTpm),
      ),
      throwsArgumentError,
    );
    await expectLater(
      backend.runManagerAction(
        ManagerActionRequest(
          ManagerActionType.startCheck,
          recoveryPassword: Uint8List.fromList([1]),
        ),
      ),
      throwsArgumentError,
    );
  });

  group('setup completion', () {
    test('accepts complete live state with current-process evidence', () {
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(),
          true,
          passwordRecoveryVerified: true,
          tpmUnlockVerified: true,
        ),
        returnsNormally,
      );
    });

    test('accepts an unencrypted installation without recovery or TPM', () {
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(luks: false, tpmConfigured: false),
          false,
          passwordRecoveryVerified: false,
          tpmUnlockVerified: false,
        ),
        returnsNormally,
      );
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(luks: false, tpmConfigured: false),
          true,
          passwordRecoveryVerified: false,
          tpmUnlockVerified: false,
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('LUKS root volume'),
        )),
      );
    });

    test('requires recovery, TPM, Secure Boot, and official fallback', () {
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(),
          false,
          passwordRecoveryVerified: false,
          tpmUnlockVerified: false,
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('password recovery test'),
        )),
      );
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(tpmConfigured: false),
          true,
          passwordRecoveryVerified: true,
          tpmUnlockVerified: true,
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('working TPM token'),
        )),
      );
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(secureBoot: false),
          false,
          passwordRecoveryVerified: true,
          tpmUnlockVerified: false,
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Secure Boot'),
        )),
      );
      expect(
        () => assertSetupCanComplete(
          _completeSnapshot(officialFallback: false),
          false,
          passwordRecoveryVerified: true,
          tpmUnlockVerified: false,
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('official Ubuntu fallback'),
        )),
      );
    });
  });

  test('clears stale reboot-required state after the target kernel boots', () {
    final pending = resolveRebootStatus(
      true,
      '7.0.13-29-hibernate',
      '7.0.12-28-hibernate',
      'installed-reboot-required',
    );
    expect(pending.rebootRequired, isTrue);
    expect(pending.lastCheckStatus, 'installed-reboot-required');

    final current = resolveRebootStatus(
      true,
      '7.0.13-29-hibernate',
      '7.0.13-29-hibernate',
      'installed-reboot-required',
    );
    expect(current.rebootRequired, isFalse);
    expect(current.lastCheckStatus, 'current');
  });
}
