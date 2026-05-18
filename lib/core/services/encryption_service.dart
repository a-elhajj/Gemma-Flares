import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages the AES-256 database encryption key, stored in the iOS Keychain
/// with accessibility kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
/// The key is inaccessible while the device is locked, matching the stated
/// security model for PHI-containing data.
class EncryptionService {
  static const _keyAlias = 'gemma_flares.db.key.v1';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      // kSecAttrAccessibleWhenUnlockedThisDeviceOnly: accessible only when
      // the device is unlocked; never migrated to a new device via backup.
      // Previously used first_unlock_this_device which allowed access while
      // locked (after first boot), exposing the PHI encryption key at rest.
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  /// Returns the stored key, generating one if none exists yet.
  static Future<String> getMasterKey() async {
    final existing = await _storage.read(key: _keyAlias);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final key = _generateKey();
    await _storage.write(key: _keyAlias, value: key);
    return key;
  }

  /// Generates a cryptographically random 64-character hex key (256 bits).
  static String _generateKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
