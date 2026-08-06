import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum DesktopUpdateKind { manager, kernel }

abstract interface class ManagerNotificationService {
  Future<void> initialize();

  Future<void> showUpdate({
    required DesktopUpdateKind kind,
    required String version,
    required String title,
    required String body,
    required String actionLabel,
    required FutureOr<void> Function() onOpen,
  });
}

class NoopManagerNotificationService implements ManagerNotificationService {
  const NoopManagerNotificationService();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> showUpdate({
    required DesktopUpdateKind kind,
    required String version,
    required String title,
    required String body,
    required String actionLabel,
    required FutureOr<void> Function() onOpen,
  }) async {}
}

class LinuxManagerNotificationService implements ManagerNotificationService {
  const LinuxManagerNotificationService();

  static const _helper =
      '/opt/secure-hibernate-manager/resources/desktop-update-notify.py';
  static const _monitorPath = 'secure-hibernate-update-notify.path';
  static const _monitorService = 'secure-hibernate-update-notify.service';

  @override
  Future<void> initialize() async {
    await _runSystemctl(const ['--user', 'daemon-reload']);
    await _runSystemctl(const [
      '--user',
      'start',
      _monitorPath,
      _monitorService,
    ]);
  }

  @override
  Future<void> showUpdate({
    required DesktopUpdateKind kind,
    required String version,
    required String title,
    required String body,
    required String actionLabel,
    required FutureOr<void> Function() onOpen,
  }) async {
    final arguments = [
      'show',
      '--kind',
      kind.name,
      '--version',
      version,
      '--title',
      title,
      '--body',
      body,
      '--action-label',
      actionLabel,
    ];
    final process = await Process.start(_helper, arguments);
    final stdoutFuture = _readBounded(process.stdout);
    final stderrFuture = _readBounded(process.stderr);
    final exitCode = await process.exitCode;
    final output = await stdoutFuture;
    final error = await stderrFuture;
    if (exitCode != 0) {
      throw ProcessException(
        _helper,
        arguments,
        error.trim().isEmpty ? 'Notification helper failed' : error.trim(),
        exitCode,
      );
    }
    if (output.trim() == 'default') await onOpen();
  }

  static Future<void> _runSystemctl(List<String> arguments) async {
    final result = await Process.run('/usr/bin/systemctl', arguments);
    if (result.exitCode != 0) {
      final error = '${result.stderr}'.trim();
      throw ProcessException(
        '/usr/bin/systemctl',
        arguments,
        error.isEmpty ? 'Could not start notification monitor' : error,
        result.exitCode,
      );
    }
  }
}

Future<String> _readBounded(
  Stream<List<int>> stream, {
  int limit = 4096,
}) async {
  final bytes = BytesBuilder(copy: false);
  var remaining = limit;
  await for (final chunk in stream) {
    if (remaining <= 0) continue;
    final copied =
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining);
    bytes.add(copied);
    remaining -= copied.length;
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}
