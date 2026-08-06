import 'package:flutter_test/flutter_test.dart';
import 'package:secure_hibernate_manager/src/app_state.dart';
import 'package:secure_hibernate_manager/src/pages/installation_wizard.dart';

void main() {
  test('accepts running Linux kernel releases at or above 7.0.0', () {
    expect(kernelReleaseMeetsMinimum('7.0.0-generic'), isTrue);
    expect(
      kernelReleaseMeetsMinimum('7.0.12-28-hibernate'),
      isTrue,
    );
    expect(
      kernelReleaseMeetsMinimum('7.0.12-29-vmstat-hibernate'),
      isTrue,
    );
    expect(kernelReleaseMeetsMinimum('7.1.0-custom'), isTrue);
    expect(kernelReleaseMeetsMinimum('8.0.0'), isTrue);
  });

  test('rejects older or malformed running kernel releases', () {
    expect(kernelReleaseMeetsMinimum('6.18.9-generic'), isFalse);
    expect(kernelReleaseMeetsMinimum('Linux 7.0.0'), isFalse);
    expect(kernelReleaseMeetsMinimum('unknown'), isFalse);
    expect(kernelReleaseMeetsMinimum(''), isFalse);
  });

  test('release builds cannot select an unreached wizard step', () {
    expect(
      wizardStepIsSelectable(
        debugMode: false,
        requestedStep: 4,
        furthestStep: 2,
      ),
      isFalse,
    );
    expect(
      wizardStepIsSelectable(
        debugMode: false,
        requestedStep: 1,
        furthestStep: 2,
      ),
      isTrue,
    );
    expect(
      wizardStepIsSelectable(
        debugMode: true,
        requestedStep: 6,
        furthestStep: 0,
      ),
      isTrue,
    );
  });

  test('maps every updater state without treating failures as success', () {
    const expected = <String, DownloadPhase>{
      'paused': DownloadPhase.paused,
      'verified': DownloadPhase.complete,
      'already-staged': DownloadPhase.complete,
      'update-available': DownloadPhase.complete,
      'current': DownloadPhase.current,
      'installed-reboot-required': DownloadPhase.rebootRequired,
      'package-manager-busy': DownloadPhase.packageManagerBusy,
      'install-failed': DownloadPhase.installFailed,
      'release-unavailable': DownloadPhase.releaseUnavailable,
      'downgrade-refused': DownloadPhase.downgradeRefused,
      'check-failed': DownloadPhase.failed,
      'manual': DownloadPhase.idle,
    };
    for (final entry in expected.entries) {
      expect(
        downloadPhaseForUpdaterStatus(
          entry.key,
          checkServiceActive: false,
        ),
        entry.value,
        reason: entry.key,
      );
    }
    const running = <String, DownloadPhase>{
      'indexing': DownloadPhase.indexing,
      'downloading': DownloadPhase.downloading,
      'verifying-manifest': DownloadPhase.verifyingManifest,
      'verifying-packages': DownloadPhase.verifyingPackages,
      'authorizing-version': DownloadPhase.authorizingVersion,
    };
    for (final entry in running.entries) {
      expect(
        downloadPhaseForUpdaterStatus(
          entry.key,
          checkServiceActive: true,
        ),
        entry.value,
        reason: entry.key,
      );
      expect(
        downloadPhaseForUpdaterStatus(
          entry.key,
          checkServiceActive: false,
        ),
        DownloadPhase.failed,
        reason: 'stale ${entry.key}',
      );
    }
    expect(
      downloadPhaseForUpdaterStatus(null, checkServiceActive: false),
      DownloadPhase.idle,
    );
    expect(
      downloadPhaseForUpdaterStatus(
        'future-state',
        checkServiceActive: false,
      ),
      DownloadPhase.unknown,
    );
    expect(
      downloadPhaseForUpdaterStatus(
        'future-state',
        checkServiceActive: true,
      ),
      DownloadPhase.indexing,
    );
    expect(
      downloadPhaseForUpdaterStatus(
        'release-unavailable',
        checkServiceActive: true,
      ),
      DownloadPhase.indexing,
    );
  });

  test('maps persisted check failures to their exact detail row', () {
    const expected = <String?, int>{
      null: 0,
      'indexing': 0,
      'downloading': 1,
      'verifying-manifest': 2,
      'verifying-packages': 3,
      'authorizing-version': 4,
      'future-phase': 0,
    };
    for (final entry in expected.entries) {
      expect(checkFailureRowIndex(entry.key), entry.value, reason: entry.key);
    }
  });
}
