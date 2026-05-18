import 'dart:convert';
import 'dart:io';

const schemaVersion = 1;
const runsRoot = 'tooling/gemma_eval/out/runs';

class Args {
  Args(this.values);

  final Map<String, String> values;

  static Args parse(List<String> args) {
    final values = <String, String>{};
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (!arg.startsWith('--')) continue;
      final withoutPrefix = arg.substring(2);
      final equals = withoutPrefix.indexOf('=');
      if (equals != -1) {
        values[withoutPrefix.substring(0, equals)] = withoutPrefix.substring(
          equals + 1,
        );
      } else if (index + 1 < args.length && !args[index + 1].startsWith('--')) {
        values[withoutPrefix] = args[++index];
      } else {
        values[withoutPrefix] = 'true';
      }
    }
    return Args(values);
  }

  String? operator [](String key) => values[key];

  bool flag(String key) => values[key] == 'true';
}

String nowUtc() => DateTime.now().toUtc().toIso8601String();

String shell(String command, {String fallback = 'unknown'}) {
  try {
    final result = Process.runSync('/bin/zsh', ['-lc', command]);
    if (result.exitCode != 0) return fallback;
    final value = result.stdout.toString().trim();
    return value.isEmpty ? fallback : value;
  } catch (_) {
    return fallback;
  }
}

String defaultRunId([String suite = 'persona_suite']) {
  final stamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll('-', '')
      .replaceAll(':', '')
      .split('.')
      .first;
  final sha = shell('git rev-parse --short HEAD', fallback: 'nogit');
  return '${stamp}Z_${sha}_$suite';
}

Directory runDir(String runId) => Directory('$runsRoot/$runId');

File runFile(String runId, String relativePath) {
  final file = File('${runDir(runId).path}/$relativePath');
  file.parent.createSync(recursive: true);
  return file;
}

Iterable<Map<String, Object?>> readJsonl(String path) sync* {
  final file = File(path);
  if (!file.existsSync()) return;
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, Object?>) yield decoded;
  }
}

void writeJson(File file, Map<String, Object?> value) {
  file.parent.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');
  file.writeAsStringSync('${encoder.convert(value)}\n');
}

void writeJsonl(File file, Iterable<Map<String, Object?>> rows) {
  file.parent.createSync(recursive: true);
  final sink = file.openWrite();
  for (final row in rows) {
    sink.writeln(jsonEncode(row));
  }
  sink.close();
}

Map<String, Object?> readJsonFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return <String, Object?>{};
  final decoded = jsonDecode(file.readAsStringSync());
  return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
}

List<Object?> asList(Object? value) => value is List ? value : const [];

String asText(Object? value, [String fallback = '']) =>
    value?.toString() ?? fallback;

bool asBool(Object? value) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return false;
}

int asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String slug(String value) {
  final normalized = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return normalized.isEmpty ? 'unknown' : normalized;
}

String oneLine(String value, {int max = 180}) {
  final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= max) return compact;
  return '${compact.substring(0, max - 3)}...';
}
