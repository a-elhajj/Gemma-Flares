// litert_lm_download_service.dart
// Gemma Flares — First-run downloader for the Gemma 4 E2B LiteRT-LM model file.
//
// Downloads the single `.litertlm` model file from HuggingFace, verifies
// SHA-256, performs an atomic rename on completion, and writes an install
// manifest so subsequent launches skip the download.
//
// Install layout:
//   <ApplicationSupport>/GemmaFlares/LiteRtLm/gemma-4-e2b-it/<revision>/model.litertlm
//
// This service owns retry/backoff, progress callbacks, low-storage checks, and
// resumable partial-file downloads for the LiteRT-LM model artifact.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// MARK: - Artifact definition
// ---------------------------------------------------------------------------

class LiteRtLmArtifact {
  const LiteRtLmArtifact({
    required this.id,
    required this.label,
    required this.revision,
    required String url,
    required this.sha256Hex,
    required this.minimumBytes,
  }) : urlString = url;

  final String id;
  final String label;

  /// HuggingFace revision SHA (full 40-char hex). Pinned; never "main".
  final String revision;

  final String urlString;
  Uri get url => Uri.parse(urlString);
  final String sha256Hex;
  String get filename => p.basename(url.path);

  /// Minimum expected file size in bytes. Used for size sanity checks.
  final int minimumBytes;
}

// ---------------------------------------------------------------------------
// MARK: - Progress callback
// ---------------------------------------------------------------------------

class LiteRtLmDownloadProgress {
  const LiteRtLmDownloadProgress({
    required this.phase,
    required this.artifact,
    this.receivedBytes = 0,
    this.totalBytes,
  });

  final String phase;
  final LiteRtLmArtifact artifact;
  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

// ---------------------------------------------------------------------------
// MARK: - Result
// ---------------------------------------------------------------------------

class LiteRtLmDownloadResult {
  const LiteRtLmDownloadResult({
    required this.artifact,
    required this.modelFile,
    required this.installDirectory,
  });

  final LiteRtLmArtifact artifact;
  final File modelFile;
  final Directory installDirectory;
}

// ---------------------------------------------------------------------------
// MARK: - Exception
// ---------------------------------------------------------------------------

class LiteRtLmDownloadException implements Exception {
  const LiteRtLmDownloadException({
    required this.code,
    required this.message,
    this.cause,
    this.artifact,
  });

  final String code;
  final String message;
  final Object? cause;
  final LiteRtLmArtifact? artifact;

  String get userMessage => switch (code) {
        'network_unavailable' =>
          'Cannot reach the model server. Check your connection.',
        'server_unauthorized' =>
          'The model server rejected the request. Please update the app.',
        'server_not_found' =>
          'The model file is missing on the server. Please update the app.',
        'server_unavailable' =>
          'The model server is temporarily unavailable. Please try again.',
        'unexpected_payload' =>
          'The model server returned an invalid model file. Please update the app.',
        'storage_unavailable' =>
          'Not enough free storage to install the model.',
        'checksum_mismatch' =>
          'The downloaded model file is corrupted. Please try again.',
        'integrity_mismatch' =>
          'The installed model file failed its integrity check.',
        _ => 'Model installation failed. ($code)',
      };

  @override
  String toString() => 'LiteRtLmDownloadException($code): $message';
}

// ---------------------------------------------------------------------------
// MARK: - Service
// ---------------------------------------------------------------------------

class LiteRtLmModelDownloadService {
  LiteRtLmModelDownloadService({
    HttpClient? httpClient,
    MethodChannel? platformChannel,
    int maxTransientRetries = 6,
  })  : _httpClient = httpClient ?? HttpClient(),
        _platformChannel =
            platformChannel ?? const MethodChannel('com.gutguard/litert_lm'),
        _maxTransientRetries = maxTransientRetries;

  static const defaultArtifact = LiteRtLmArtifact(
    id: 'gemma-4-e2b-it-litert-lm',
    label: 'Gemma 4 E2B (LiteRT-LM)',
    revision: 'b4f4f4df93418ddb4aa7da8bf33b584602a5b9f8',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b4f4f4df93418ddb4aa7da8bf33b584602a5b9f8/gemma-4-E2B-it.litertlm',
    sha256Hex:
        '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    // LiteRT-LM E2B is 2,588,147,712 bytes on Hugging Face. Keep this
    // strictly above the release verifier's 2.5 GB floor so truncated files
    // fail fast before the expensive SHA-256 pass.
    minimumBytes: 2500000001,
  );

  static const _installManifestFileName = '.litert_lm_install_manifest.json';
  static const _partialSuffix = '.part';
  static const _installSubdir = 'LiteRtLm';

  final HttpClient _httpClient;
  final MethodChannel _platformChannel;
  final int _maxTransientRetries;

  Future<LiteRtLmDownloadResult>? _downloadInFlight;

  // ---------------------------------------------------------------------------
  // MARK: - Public API
  // ---------------------------------------------------------------------------

  /// Returns the root directory where LiteRT-LM models are stored.
  Future<Directory> installDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'GemmaFlares', _installSubdir));
  }

  /// Returns the directory for [artifact] at its specific revision.
  Future<Directory> revisionDirectory(LiteRtLmArtifact artifact) async {
    final root = await installDirectory();
    return Directory(p.join(root.path, artifact.id, artifact.revision));
  }

  /// Returns `true` if the model for [artifact] is already installed and passes
  /// the install manifest + minimum-size check.
  Future<bool> hasInstalledArtifact(
      [LiteRtLmArtifact artifact = defaultArtifact]) async {
    final dir = await revisionDirectory(artifact);
    final modelFile = File(p.join(dir.path, 'model.litertlm'));
    if (!await modelFile.exists()) return false;
    if (await modelFile.length() < artifact.minimumBytes) return false;
    return _installManifestMatches(artifact, dir);
  }

  /// Download [artifact] (or the default one), verify SHA-256, and atomically
  /// rename to the install location. Idempotent: if already installed, returns
  /// immediately. Multiple concurrent callers share a single in-flight future.
  Future<LiteRtLmDownloadResult> downloadRequired({
    void Function(LiteRtLmDownloadProgress)? onProgress,
    LiteRtLmArtifact artifact = defaultArtifact,
  }) {
    final existing = _downloadInFlight;
    if (existing != null) return existing;

    final future = _download(artifact, onProgress: onProgress);
    _downloadInFlight = future;
    return future.whenComplete(() {
      if (identical(_downloadInFlight, future)) _downloadInFlight = null;
    });
  }

  /// Remove the installed model for [artifact] (and any partial downloads).
  Future<void> resetArtifact(
      [LiteRtLmArtifact artifact = defaultArtifact]) async {
    _downloadInFlight = null;
    final root = await installDirectory();
    final idDir = Directory(p.join(root.path, artifact.id));
    if (await idDir.exists()) await idDir.delete(recursive: true);

    // Remove old revisions too.
    if (await root.exists()) {
      await for (final entity in root.list()) {
        if (entity is Directory &&
            entity.path.contains(artifact.id) &&
            !entity.path.contains(artifact.revision)) {
          await entity.delete(recursive: true);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // MARK: - Internal
  // ---------------------------------------------------------------------------

  Future<LiteRtLmDownloadResult> _download(
    LiteRtLmArtifact artifact, {
    void Function(LiteRtLmDownloadProgress)? onProgress,
  }) async {
    final revDir = await revisionDirectory(artifact);
    final modelFile = File(p.join(revDir.path, 'model.litertlm'));

    // Fast-path: already installed and manifest matches.
    if (await hasInstalledArtifact(artifact)) {
      onProgress?.call(LiteRtLmDownloadProgress(
        phase: 'already_installed',
        artifact: artifact,
        receivedBytes: await modelFile.length(),
        totalBytes: await modelFile.length(),
      ));
      return LiteRtLmDownloadResult(
        artifact: artifact,
        modelFile: modelFile,
        installDirectory: revDir,
      );
    }

    await revDir.create(recursive: true);

    // Preflight: enough free storage?
    await _preflightFreeSpace(artifact, revDir);

    final partial = File('${modelFile.path}$_partialSuffix');

    await _downloadWithRetry(artifact, partial, onProgress: onProgress);

    // Atomic rename: partial → final.
    try {
      if (await modelFile.exists()) await modelFile.delete();
      await partial.rename(modelFile.path);
    } on FileSystemException catch (e) {
      if (await partial.exists()) {
        try {
          await partial.delete();
        } on FileSystemException {
          // Best-effort cleanup only.
        }
      }
      throw LiteRtLmDownloadException(
        code: 'storage_unavailable',
        message: 'Could not finalize model file for ${artifact.label}.',
        cause: e,
        artifact: artifact,
      );
    }

    // Make model file read-only as a security hardening measure.
    try {
      await Process.run('chmod', ['444', modelFile.path]);
    } catch (_) {
      // Non-fatal; chmod failure is logged but does not abort installation.
    }

    // Write install manifest.
    await _writeInstallManifest(artifact, revDir, modelFile);

    // Garbage-collect stale revisions in the background.
    unawaited(_gcOldRevisions(artifact));

    return LiteRtLmDownloadResult(
      artifact: artifact,
      modelFile: modelFile,
      installDirectory: revDir,
    );
  }

  Future<void> _preflightFreeSpace(
      LiteRtLmArtifact artifact, Directory dir) async {
    final freeBytes = await _freeDiskBytes(dir.path);
    if (freeBytes < 0) return; // Cannot determine; proceed optimistically.
    // Require 1.5× the minimum bytes: download + atomic rename headroom.
    final required = (artifact.minimumBytes * 3) ~/ 2;
    if (freeBytes < required) {
      final freeGb = (freeBytes / (1 << 30)).toStringAsFixed(1);
      final reqGb = (required / (1 << 30)).toStringAsFixed(1);
      throw LiteRtLmDownloadException(
        code: 'storage_unavailable',
        message:
            'Need ~$reqGb GB free to install ${artifact.label}; only $freeGb GB available.',
        artifact: artifact,
      );
    }
  }

  Future<void> _downloadWithRetry(
    LiteRtLmArtifact artifact,
    File partial, {
    void Function(LiteRtLmDownloadProgress)? onProgress,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        await _downloadChunk(artifact, partial, onProgress: onProgress);
        return;
      } on LiteRtLmDownloadException catch (e) {
        if (e.code == 'checksum_mismatch') rethrow; // Not transient.
        if (e.code == 'storage_unavailable') rethrow; // Not transient.
        if (attempt >= _maxTransientRetries) rethrow;
        attempt++;
        // Jittered exponential backoff: base 2^attempt seconds ± 25%.
        final baseMs = (1000 * (1 << attempt)).clamp(1000, 32000);
        final jitter = (baseMs * 0.25 * (attempt % 3 == 0 ? 1 : -1)).round();
        await Future<void>.delayed(Duration(milliseconds: baseMs + jitter));
      }
    }
  }

  Future<void> _downloadChunk(
    LiteRtLmArtifact artifact,
    File partial, {
    void Function(LiteRtLmDownloadProgress)? onProgress,
  }) async {
    // Resume support: read how many bytes we already have.
    var resumeFromBytes = 0;
    if (await partial.exists()) {
      resumeFromBytes = await partial.length();
    }
    final isResumed = resumeFromBytes > 0;

    late HttpClientRequest request;
    try {
      request = await _httpClient.getUrl(artifact.url);
      request.followRedirects = true;
      request.maxRedirects = 8;
      if (isResumed) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFromBytes-');
      }
    } on SocketException catch (e) {
      throw LiteRtLmDownloadException(
        code: 'network_unavailable',
        message: 'Cannot reach model host for ${artifact.label}.',
        cause: e,
        artifact: artifact,
      );
    } on HandshakeException catch (e) {
      throw LiteRtLmDownloadException(
        code: 'network_unavailable',
        message: 'TLS handshake failed for ${artifact.label}.',
        cause: e,
        artifact: artifact,
      );
    }

    late HttpClientResponse response;
    try {
      response = await request.close();
    } on SocketException catch (e) {
      throw LiteRtLmDownloadException(
        code: 'network_unavailable',
        message: 'Connection closed before response for ${artifact.label}.',
        cause: e,
        artifact: artifact,
      );
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw LiteRtLmDownloadException(
        code: _downloadErrorCodeForStatus(response.statusCode),
        message: 'Model server returned HTTP ${response.statusCode} for '
            '${artifact.label} at ${artifact.url}.',
        artifact: artifact,
      );
    }

    // Sanity check: content-length vs expected minimum.
    final contentLength =
        response.contentLength > 0 ? response.contentLength : null;
    final total = contentLength == null
        ? null
        : (isResumed ? resumeFromBytes + contentLength : contentLength);
    if (total != null && total < artifact.minimumBytes ~/ 2) {
      await response.drain<void>();
      throw LiteRtLmDownloadException(
        code: 'unexpected_payload',
        message: 'Server returned unexpectedly small payload for '
            '${artifact.label} ($total bytes).',
        artifact: artifact,
      );
    }

    // Stream to disk while hashing.
    Digest? digest;
    final digestCapture = sha256.startChunkedConversion(
      _DigestCaptureSink((d) => digest = d),
    );

    final output = partial.openWrite(mode: FileMode.append);
    var received = isResumed ? resumeFromBytes : 0;

    // Re-hash already-downloaded bytes so the final digest covers the whole file.
    if (isResumed) {
      final existing = partial.openRead(0, resumeFromBytes);
      await for (final chunk in existing) {
        digestCapture.add(chunk);
      }
    }

    try {
      await for (final chunk in response) {
        received += chunk.length;
        digestCapture.add(chunk);
        output.add(chunk);
        onProgress?.call(LiteRtLmDownloadProgress(
          phase: 'downloading',
          artifact: artifact,
          receivedBytes: received,
          totalBytes: total,
        ));
      }
      await output.flush();
      await output.close();
      digestCapture.close();
    } on FileSystemException catch (e) {
      try {
        await output.close();
      } on FileSystemException {
        // The storage exception below is the actionable failure.
      }
      throw LiteRtLmDownloadException(
        code: 'storage_unavailable',
        message: 'Disk write failed for ${artifact.label}.',
        cause: e,
        artifact: artifact,
      );
    }

    // Validate SHA-256.
    final expectedSha = artifact.sha256Hex;
    final actual = digest?.toString() ?? '';
    if (actual != expectedSha) {
      try {
        await partial.delete();
      } on FileSystemException {
        // Best-effort cleanup only.
      }
      throw LiteRtLmDownloadException(
        code: 'checksum_mismatch',
        message: 'SHA-256 mismatch for ${artifact.label}. '
            'Expected $expectedSha, got $actual.',
        artifact: artifact,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // MARK: - Manifest helpers
  // ---------------------------------------------------------------------------

  Future<bool> _installManifestMatches(
    LiteRtLmArtifact artifact,
    Directory dir,
  ) async {
    try {
      final file = File(p.join(dir.path, _installManifestFileName));
      if (!await file.exists()) return false;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      return decoded['artifact_id'] == artifact.id &&
          decoded['revision'] == artifact.revision &&
          decoded['sha256'] == artifact.sha256Hex;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeInstallManifest(
    LiteRtLmArtifact artifact,
    Directory dir,
    File modelFile,
  ) async {
    final manifest = File(p.join(dir.path, _installManifestFileName));
    const encoder = JsonEncoder.withIndent('  ');
    final content = encoder.convert({
      'schema_version': 1,
      'artifact_id': artifact.id,
      'revision': artifact.revision,
      'sha256': artifact.sha256Hex,
      'model_file': p.basename(modelFile.path),
      'model_bytes': await modelFile.length(),
      'installed_at': DateTime.now().toUtc().toIso8601String(),
    });
    await manifest.writeAsString('$content\n', flush: true);
  }

  // ---------------------------------------------------------------------------
  // MARK: - Cold-start integrity check
  // ---------------------------------------------------------------------------

  /// Verify the installed model's SHA-256 on every cold start.
  /// Returns `true` if the file is intact, `false` if it should be re-downloaded.
  Future<bool> verifyInstalledIntegrity(
      [LiteRtLmArtifact artifact = defaultArtifact]) async {
    final revDir = await revisionDirectory(artifact);
    final modelFile = File(p.join(revDir.path, 'model.litertlm'));
    if (!await modelFile.exists()) return false;
    if (await modelFile.length() < artifact.minimumBytes) return false;
    try {
      final fileDigest = await sha256.bind(modelFile.openRead()).first;
      return fileDigest.toString() == artifact.sha256Hex;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // MARK: - GC stale revisions
  // ---------------------------------------------------------------------------

  Future<void> _gcOldRevisions(LiteRtLmArtifact artifact) async {
    try {
      final root = await installDirectory();
      final idDir = Directory(p.join(root.path, artifact.id));
      if (!await idDir.exists()) return;
      await for (final entity in idDir.list()) {
        if (entity is Directory &&
            p.basename(entity.path) != artifact.revision) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {
      // GC failure is non-fatal.
    }
  }

  // ---------------------------------------------------------------------------
  // MARK: - Platform helpers
  // ---------------------------------------------------------------------------

  Future<int> _freeDiskBytes(String path) async {
    try {
      final raw = await _platformChannel.invokeMethod<Object?>(
        'getFreeDiskBytes',
        {'path': path},
      );
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
    } catch (_) {
      // Fall through; -1 means unknown.
    }
    return -1;
  }
}

// ---------------------------------------------------------------------------
// MARK: - Internal hash sink helpers
// ---------------------------------------------------------------------------

class _DigestCaptureSink implements Sink<Digest> {
  _DigestCaptureSink(this._onDigest);
  final void Function(Digest) _onDigest;
  @override
  void add(Digest data) => _onDigest(data);
  @override
  void close() {}
}

String _downloadErrorCodeForStatus(int statusCode) {
  if (statusCode == 401 || statusCode == 403) return 'server_unauthorized';
  if (statusCode == 404 || statusCode == 410) return 'server_not_found';
  if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
    return 'server_unavailable';
  }
  return 'unexpected_payload';
}

void unawaited(Future<void> future) {
  future.ignore();
}
