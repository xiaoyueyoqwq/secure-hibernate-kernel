import 'dart:async';
import 'dart:convert';
import 'dart:io';

const managerCurrentVersion = String.fromEnvironment(
  'MANAGER_VERSION',
  defaultValue: '1.0.0+29',
);

const _releaseApiUrl =
    'https://api.github.com/repos/xiaoyueyoqwq/secure-hibernate-kernel/releases?per_page=30';
const _releaseOwner = 'xiaoyueyoqwq';
const _releaseRepository = 'secure-hibernate-kernel';
const _xdgOpen = '/usr/bin/xdg-open';
const _maxResponseBytes = 2 * 1024 * 1024;
final _managerVersionPattern = RegExp(
  r'^manager-v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+(\d+))?$',
);

enum ManagerUpdateState { unknown, checking, current, available, error }

class ManagerUpdateInfo {
  const ManagerUpdateInfo({
    required this.state,
    required this.currentVersion,
    this.latestVersion,
    this.releaseUrl,
    this.error,
  });

  const ManagerUpdateInfo.unknown()
      : state = ManagerUpdateState.unknown,
        currentVersion = managerCurrentVersion,
        latestVersion = null,
        releaseUrl = null,
        error = null;

  final ManagerUpdateState state;
  final String currentVersion;
  final String? latestVersion;
  final String? releaseUrl;
  final String? error;
}

abstract interface class ManagerUpdateChecker {
  Future<ManagerUpdateInfo> check(String currentVersion);
}

class FixedManagerUpdateChecker implements ManagerUpdateChecker {
  const FixedManagerUpdateChecker();

  @override
  Future<ManagerUpdateInfo> check(String currentVersion) async =>
      ManagerUpdateInfo(
        state: ManagerUpdateState.current,
        currentVersion: currentVersion,
        latestVersion: currentVersion,
      );
}

class GitHubManagerUpdateChecker implements ManagerUpdateChecker {
  const GitHubManagerUpdateChecker();

  @override
  Future<ManagerUpdateInfo> check(String currentVersion) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'secure-hibernate-manager/$currentVersion';
    try {
      final request = await client.getUrl(Uri.parse(_releaseApiUrl));
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        return ManagerUpdateInfo(
          state: ManagerUpdateState.error,
          currentVersion: currentVersion,
          error: 'Release service returned HTTP ${response.statusCode}',
        );
      }
      final body = await _readBounded(response);
      final decoded = jsonDecode(body);
      if (decoded is! List<dynamic>) {
        return _error(currentVersion, 'Release service returned invalid data');
      }
      final releases = <_ManagerRelease>[];
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic> ||
            entry['draft'] == true ||
            entry['prerelease'] == true ||
            entry['tag_name'] is! String) {
          continue;
        }
        final version = _ManagerVersion.parse(entry['tag_name'] as String);
        if (version == null) continue;
        final url = entry['html_url'];
        releases.add(_ManagerRelease(
          version,
          url is String && _trustedManagerReleaseUri(url) != null ? url : null,
        ));
      }
      if (releases.isEmpty) {
        return _error(currentVersion, 'No Manager Release found');
      }
      releases.sort((a, b) => b.version.compareTo(a.version));
      final latest = releases.first;
      if (latest.url == null) {
        return _error(currentVersion, 'Manager Release URL is invalid');
      }
      final installed = _ManagerVersion.parse('manager-v$currentVersion');
      if (installed == null) {
        return _error(currentVersion, 'Installed Manager version is invalid');
      }
      final state = latest.version.compareTo(installed) > 0
          ? ManagerUpdateState.available
          : ManagerUpdateState.current;
      return ManagerUpdateInfo(
        state: state,
        currentVersion: currentVersion,
        latestVersion: latest.version.display,
        releaseUrl: latest.url,
      );
    } on TimeoutException {
      return _error(currentVersion, 'Release check timed out');
    } on FormatException {
      return _error(currentVersion, 'Release service returned invalid data');
    } on Object catch (error) {
      return _error(currentVersion, error.toString());
    } finally {
      client.close(force: true);
    }
  }

  ManagerUpdateInfo _error(String currentVersion, String error) =>
      ManagerUpdateInfo(
        state: ManagerUpdateState.error,
        currentVersion: currentVersion,
        error: error.length > 240 ? error.substring(0, 240) : error,
      );
}

Uri? _trustedManagerReleaseUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.length != 5 ||
      segments[0] != _releaseOwner ||
      segments[1] != _releaseRepository ||
      segments[2] != 'releases' ||
      segments[3] != 'tag' ||
      _ManagerVersion.parse(segments[4]) == null) {
    return null;
  }
  return uri;
}

Future<void> openManagerRelease(String releaseUrl) async {
  final uri = _trustedManagerReleaseUri(releaseUrl);
  if (uri == null) {
    throw const FormatException('Manager Release URL is invalid');
  }
  final result = await Process.run(_xdgOpen, [uri.toString()]);
  if (result.exitCode != 0) {
    final detail = result.stderr.toString().trim();
    throw ProcessException(
      _xdgOpen,
      [uri.toString()],
      detail.isEmpty ? 'Unable to open the Manager Release' : detail,
      result.exitCode,
    );
  }
}

Future<String> _readBounded(HttpClientResponse response) async {
  final buffer = StringBuffer();
  var length = 0;
  await for (final chunk in response.transform(utf8.decoder)) {
    length += chunk.length;
    if (length > _maxResponseBytes) {
      throw const FormatException('Release response exceeds the size limit');
    }
    buffer.write(chunk);
  }
  return buffer.toString();
}

class _ManagerRelease {
  const _ManagerRelease(this.version, this.url);

  final _ManagerVersion version;
  final String? url;
}

class _ManagerVersion implements Comparable<_ManagerVersion> {
  const _ManagerVersion(this.major, this.minor, this.patch, this.prerelease,
      this.build, this.display);

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;
  final int build;
  final String display;

  static _ManagerVersion? parse(String tag) {
    final match = _managerVersionPattern.firstMatch(tag);
    if (match == null) return null;
    return _ManagerVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4),
      int.tryParse(match.group(5) ?? '') ?? 0,
      tag.substring('manager-v'.length),
    );
  }

  @override
  int compareTo(_ManagerVersion other) {
    for (final comparison in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (comparison != 0) return comparison;
    }
    if (prerelease == null && other.prerelease != null) return 1;
    if (prerelease != null && other.prerelease == null) return -1;
    final preComparison = (prerelease ?? '').compareTo(other.prerelease ?? '');
    return preComparison != 0 ? preComparison : build.compareTo(other.build);
  }
}
