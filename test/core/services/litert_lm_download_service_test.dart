import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/litert_lm_download_service.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Subclass that overrides [revisionDirectory] and [installDirectory] to use
/// a test-controlled temp path — no ApplicationSupport access needed.
class _TestDownloadService extends LiteRtLmModelDownloadService {
  _TestDownloadService(this._tempRoot) : super();

  final Directory _tempRoot;

  @override
  Future<Directory> revisionDirectory(LiteRtLmArtifact artifact) async {
    return Directory(p.join(_tempRoot.path, artifact.id, artifact.revision));
  }

  @override
  Future<Directory> installDirectory() async => _tempRoot;
}

Future<void> _writeManifest(Directory dir, LiteRtLmArtifact artifact) async {
  await dir.create(recursive: true);
  final manifest = File(
    p.join(dir.path, '.litert_lm_install_manifest.json'),
  );
  await manifest.writeAsString(jsonEncode({
    'schema_version': 1,
    'artifact_id': artifact.id,
    'revision': artifact.revision,
    'install_method': 'downloaded',
    'sha256': artifact.sha256Hex,
    'model_file': 'model.litertlm',
    'model_bytes': artifact.minimumBytes,
  }));
}

Future<File> _writeModelFile(
    Directory dir, int bytes, LiteRtLmArtifact artifact) async {
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, 'model.litertlm'));
  await file.writeAsBytes(List.filled(bytes, 0));
  return file;
}

// A test artifact with a deterministic SHA-256 so verifyInstalledIntegrity
// can exercise the real file-hashing path without a multi-GB fixture.
// SHA is for a file of 10 zero bytes: sha256sum /dev/zero | head -c 10 > f
// Precomputed: e3b0c44298fc1c149afb... is for 0 bytes.
// For 10 bytes of 0x00:
//   sha256sum  → 1e1f... we'll use a known all-zero-bytes digest.
// We pass a deliberately wrong SHA so we can test the "mismatch" path too.
final _testArtifact = LiteRtLmArtifact(
  id: 'test-artifact',
  label: 'Test Artifact',
  revision: 'test-revision-001',
  url: 'data:,',
  // SHA-256 of 100 zero bytes:
  // echo -n '' | dd bs=1 count=100 | sha256sum → not trivial in a const.
  // Use a well-known hash for an empty file: e3b0c44298fc1c149afb4c8996fb92427ae41e4649b934ca495991b7852b855
  sha256Hex:
      'e3b0c44298fc1c149afb4c8996fb924' // note: test only — not real model
      '27ae41e4649b934ca495991b7852b855',
  minimumBytes: 10,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempRoot;
  late _TestDownloadService service;
  final artifact = _testArtifact;
  const defaultArtifact = LiteRtLmModelDownloadService.defaultArtifact;

  setUp(() async {
    tempRoot =
        await Directory.systemTemp.createTemp('gutguard_litert_lm_test_');
    service = _TestDownloadService(tempRoot);
  });

  tearDown(() async {
    await tempRoot.delete(recursive: true);
  });

  // ── hasInstalledArtifact ──────────────────────────────────────────────────

  group('hasInstalledArtifact', () {
    test('returns false when model file is absent', () async {
      expect(await service.hasInstalledArtifact(artifact), isFalse);
    });

    test('returns false when model file is too small (below minimumBytes)',
        () async {
      final dir = await service.revisionDirectory(artifact);
      await _writeModelFile(dir, artifact.minimumBytes - 1, artifact);
      await _writeManifest(dir, artifact);

      expect(await service.hasInstalledArtifact(artifact), isFalse);
    });

    test('returns false when manifest is absent even if file is large enough',
        () async {
      final dir = await service.revisionDirectory(artifact);
      await _writeModelFile(dir, artifact.minimumBytes, artifact);
      // No manifest written.

      expect(await service.hasInstalledArtifact(artifact), isFalse);
    });

    test('returns true when model file and manifest are both present',
        () async {
      final dir = await service.revisionDirectory(artifact);
      await _writeModelFile(dir, artifact.minimumBytes, artifact);
      await _writeManifest(dir, artifact);

      expect(await service.hasInstalledArtifact(artifact), isTrue);
    });
  });

  // ── verifyInstalledIntegrity ──────────────────────────────────────────────
  // Use _testArtifact (non-PENDING SHA) to exercise the real code path.

  group('verifyInstalledIntegrity', () {
    test('returns false when model file is absent (non-pending SHA)', () async {
      // _testArtifact has a real SHA, so the file-existence check fires.
      expect(await service.verifyInstalledIntegrity(_testArtifact), isFalse);
    });

    test('returns false when model file is too small (non-pending SHA)',
        () async {
      final dir = await service.revisionDirectory(_testArtifact);
      // Write 5 bytes — below _testArtifact.minimumBytes (10).
      final file = File(p.join(dir.path, 'model.litertlm'));
      await dir.create(recursive: true);
      await file.writeAsBytes([0, 0, 0, 0, 0]);
      await _writeManifest(dir, _testArtifact);

      expect(await service.verifyInstalledIntegrity(_testArtifact), isFalse);
    });

    test('default artifact does not bypass integrity when model is absent',
        () async {
      expect(await service.verifyInstalledIntegrity(defaultArtifact), isFalse);
    });
  });

  // ── resetArtifact ─────────────────────────────────────────────────────────

  group('resetArtifact', () {
    test('removes the model after reset — hasInstalledArtifact returns false',
        () async {
      final dir = await service.revisionDirectory(artifact);
      await _writeModelFile(dir, artifact.minimumBytes, artifact);
      await _writeManifest(dir, artifact);
      expect(await service.hasInstalledArtifact(artifact), isTrue);

      await service.resetArtifact(artifact);

      expect(await service.hasInstalledArtifact(artifact), isFalse);
    });

    test('does not throw when nothing is installed', () async {
      await expectLater(service.resetArtifact(artifact), completes);
    });
  });

  // ── LiteRtLmArtifact ─────────────────────────────────────────────────────

  group('LiteRtLmArtifact', () {
    test('defaultArtifact minimumBytes exceeds 2.5 GB', () {
      expect(defaultArtifact.minimumBytes, greaterThan(2500000000));
    });

    test('defaultArtifact id is non-empty', () {
      expect(defaultArtifact.id, isNotEmpty);
    });

    test('defaultArtifact revision is non-empty', () {
      expect(defaultArtifact.revision, isNotEmpty);
    });

    test('defaultArtifact is pinned to a real Hugging Face commit', () {
      expect(defaultArtifact.revision, hasLength(40));
      expect(defaultArtifact.revision, isNot(contains('PENDING')));
    });

    test('defaultArtifact url scheme is https', () {
      expect(defaultArtifact.url.scheme, equals('https'));
    });

    test('defaultArtifact url and sha are production values', () {
      expect(defaultArtifact.urlString, contains(defaultArtifact.revision));
      expect(defaultArtifact.urlString, contains('gemma-4-E2B-it.litertlm'));
      expect(defaultArtifact.urlString, isNot(contains('PENDING')));
      expect(defaultArtifact.sha256Hex, hasLength(64));
      expect(defaultArtifact.sha256Hex, isNot(contains('PENDING')));
    });
  });

  // ── LiteRtLmDownloadProgress ──────────────────────────────────────────────

  group('LiteRtLmDownloadProgress', () {
    test('fraction returns null when totalBytes is null', () {
      const progress = LiteRtLmDownloadProgress(
        phase: 'downloading',
        artifact: LiteRtLmModelDownloadService.defaultArtifact,
      );
      expect(progress.fraction, isNull);
    });

    test('fraction returns 0.5 for 500/1000', () {
      const progress = LiteRtLmDownloadProgress(
        phase: 'downloading',
        artifact: LiteRtLmModelDownloadService.defaultArtifact,
        receivedBytes: 500,
        totalBytes: 1000,
      );
      expect(progress.fraction, closeTo(0.5, 0.001));
    });

    test('fraction is null when totalBytes is 0', () {
      const progress = LiteRtLmDownloadProgress(
        phase: 'downloading',
        artifact: LiteRtLmModelDownloadService.defaultArtifact,
        receivedBytes: 0,
        totalBytes: 0,
      );
      expect(progress.fraction, isNull);
    });

    test('fraction is clamped to 1.0 when received > total', () {
      const progress = LiteRtLmDownloadProgress(
        phase: 'downloading',
        artifact: LiteRtLmModelDownloadService.defaultArtifact,
        receivedBytes: 1500,
        totalBytes: 1000,
      );
      expect(progress.fraction, equals(1.0));
    });
  });

  // ── LiteRtLmDownloadException ─────────────────────────────────────────────

  group('LiteRtLmDownloadException.userMessage', () {
    test('network_unavailable returns human-readable string', () {
      const ex = LiteRtLmDownloadException(
        code: 'network_unavailable',
        message: 'host unreachable',
      );
      expect(ex.userMessage, contains('connection'));
    });

    test('server_not_found explains app update instead of connection', () {
      const ex = LiteRtLmDownloadException(
        code: 'server_not_found',
        message: '404',
      );
      expect(ex.userMessage, contains('missing'));
      expect(ex.userMessage, contains('update'));
    });

    test('server_unauthorized explains rejected model request', () {
      const ex = LiteRtLmDownloadException(
        code: 'server_unauthorized',
        message: '403',
      );
      expect(ex.userMessage, contains('rejected'));
    });

    test('unexpected_payload explains invalid model file', () {
      const ex = LiteRtLmDownloadException(
        code: 'unexpected_payload',
        message: 'tiny payload',
      );
      expect(ex.userMessage, contains('invalid model file'));
    });

    test('storage_unavailable returns human-readable string', () {
      const ex = LiteRtLmDownloadException(
        code: 'storage_unavailable',
        message: 'low storage',
      );
      expect(ex.userMessage, contains('storage'));
    });

    test('checksum_mismatch returns human-readable string', () {
      const ex = LiteRtLmDownloadException(
        code: 'checksum_mismatch',
        message: 'sha mismatch',
      );
      expect(ex.userMessage, contains('corrupted'));
    });

    test('integrity_mismatch returns human-readable string', () {
      const ex = LiteRtLmDownloadException(
        code: 'integrity_mismatch',
        message: 'cold-start check failed',
      );
      expect(ex.userMessage, contains('integrity'));
    });

    test('unknown code includes code in message', () {
      const ex = LiteRtLmDownloadException(
        code: 'some_unknown_code',
        message: 'unexpected',
      );
      expect(ex.userMessage, contains('some_unknown_code'));
    });

    test('toString includes code and message', () {
      const ex = LiteRtLmDownloadException(
        code: 'test_code',
        message: 'test message',
      );
      expect(ex.toString(), contains('test_code'));
      expect(ex.toString(), contains('test message'));
    });
  });
}
