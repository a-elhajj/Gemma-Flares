import '../database/wearable_sample_repository.dart';

class SetupStatus {
  const SetupStatus({
    this.completed = false,
    this.completedAt,
    this.profileValidatedAt,
    this.modelValidatedAt,
    this.healthValidatedAt,
    this.healthEnabled = false,
    this.healthLastBackfillAt,
    this.healthImportedSamples = 0,
    this.modelRuntimeProfile,
    this.modelBackend,
    this.schemaVersion = currentSchemaVersion,
  });

  static const empty = SetupStatus();
  static const currentSchemaVersion = 2;

  final bool completed;
  final DateTime? completedAt;
  final DateTime? profileValidatedAt;
  final DateTime? modelValidatedAt;
  final DateTime? healthValidatedAt;
  final bool healthEnabled;
  final DateTime? healthLastBackfillAt;
  final int healthImportedSamples;
  final String? modelRuntimeProfile;
  final String? modelBackend;
  final int schemaVersion;

  bool get hasValidatedProfile => profileValidatedAt != null;
  bool get hasValidatedModel => modelValidatedAt != null;
  bool get hasResolvedHealth => healthValidatedAt != null;
  bool get isCurrentSchema => schemaVersion >= currentSchemaVersion;
  bool get isReadyForAppUse =>
      completed &&
      isCurrentSchema &&
      hasValidatedProfile &&
      hasValidatedModel &&
      hasResolvedHealth;

  SetupStatus copyWith({
    bool? completed,
    DateTime? completedAt,
    DateTime? profileValidatedAt,
    DateTime? modelValidatedAt,
    DateTime? healthValidatedAt,
    bool? healthEnabled,
    DateTime? healthLastBackfillAt,
    int? healthImportedSamples,
    String? modelRuntimeProfile,
    String? modelBackend,
    int? schemaVersion,
  }) {
    return SetupStatus(
      completed: completed ?? this.completed,
      completedAt: completedAt ?? this.completedAt,
      profileValidatedAt: profileValidatedAt ?? this.profileValidatedAt,
      modelValidatedAt: modelValidatedAt ?? this.modelValidatedAt,
      healthValidatedAt: healthValidatedAt ?? this.healthValidatedAt,
      healthEnabled: healthEnabled ?? this.healthEnabled,
      healthLastBackfillAt: healthLastBackfillAt ?? this.healthLastBackfillAt,
      healthImportedSamples:
          healthImportedSamples ?? this.healthImportedSamples,
      modelRuntimeProfile: modelRuntimeProfile ?? this.modelRuntimeProfile,
      modelBackend: modelBackend ?? this.modelBackend,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  SetupStatus withDerivedCompletion({DateTime? completedAtOverride}) {
    final ready = hasValidatedProfile && hasValidatedModel && hasResolvedHealth;
    return SetupStatus(
      completed: ready,
      completedAt: ready ? completedAtOverride ?? completedAt : null,
      profileValidatedAt: profileValidatedAt,
      modelValidatedAt: modelValidatedAt,
      healthValidatedAt: healthValidatedAt,
      healthEnabled: healthEnabled,
      healthLastBackfillAt: healthLastBackfillAt,
      healthImportedSamples: healthImportedSamples,
      modelRuntimeProfile: modelRuntimeProfile,
      modelBackend: modelBackend,
      schemaVersion: currentSchemaVersion,
    );
  }

  Map<String, Object?> toJson() => {
        'completed': completed,
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'profile_validated_at': profileValidatedAt?.toUtc().toIso8601String(),
        'model_validated_at': modelValidatedAt?.toUtc().toIso8601String(),
        'health_validated_at': healthValidatedAt?.toUtc().toIso8601String(),
        'health_enabled': healthEnabled,
        'health_last_backfill_at':
            healthLastBackfillAt?.toUtc().toIso8601String(),
        'health_imported_samples': healthImportedSamples,
        'model_runtime_profile': modelRuntimeProfile,
        'model_backend': modelBackend,
        'schema_version': schemaVersion,
      };

  factory SetupStatus.fromJson(Map<String, Object?> json) {
    return SetupStatus(
      completed: json['completed'] == true,
      completedAt: _parseDateTime(json['completed_at']),
      profileValidatedAt: _parseDateTime(json['profile_validated_at']),
      modelValidatedAt: _parseDateTime(json['model_validated_at']),
      healthValidatedAt: _parseDateTime(json['health_validated_at']),
      healthEnabled: json['health_enabled'] == true,
      healthLastBackfillAt: _parseDateTime(json['health_last_backfill_at']),
      healthImportedSamples:
          (json['health_imported_samples'] as num?)?.toInt() ?? 0,
      modelRuntimeProfile: json['model_runtime_profile'] as String?,
      modelBackend: json['model_backend'] as String?,
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
    );
  }

  static DateTime? _parseDateTime(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}

class SetupStateService {
  SetupStateService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static const setupStatusKey = 'setup_status_v1';

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  Future<SetupStatus> loadStatus() async {
    final json = await _repository.getAppSettingMap(setupStatusKey);
    if (json == null) return SetupStatus.empty;
    return SetupStatus.fromJson(json);
  }

  Future<void> saveStatus(SetupStatus status) {
    return _repository.upsertAppSettingJson(
      key: setupStatusKey,
      value: status.toJson(),
    );
  }

  Future<SetupStatus> markProfileValidated() async {
    final status = await loadStatus();
    final updated = status.copyWith(
      profileValidatedAt: _nowProvider(),
      schemaVersion: SetupStatus.currentSchemaVersion,
    );
    await saveStatus(updated);
    return updated;
  }

  Future<SetupStatus> markModelValidated({
    String? runtimeProfile,
    String? backend,
  }) async {
    final status = await loadStatus();
    final updated = status
        .copyWith(
          modelValidatedAt: _nowProvider(),
          modelRuntimeProfile: runtimeProfile,
          modelBackend: backend,
          schemaVersion: SetupStatus.currentSchemaVersion,
        )
        .withDerivedCompletion(completedAtOverride: _nowProvider());
    await saveStatus(updated);
    return updated;
  }

  Future<SetupStatus> markModelNeedsRepair() async {
    final status = await loadStatus();
    final updated = SetupStatus(
      completed: false,
      completedAt: null,
      profileValidatedAt: status.profileValidatedAt,
      modelValidatedAt: null,
      healthValidatedAt: status.healthValidatedAt,
      healthEnabled: status.healthEnabled,
      healthLastBackfillAt: status.healthLastBackfillAt,
      healthImportedSamples: status.healthImportedSamples,
      modelRuntimeProfile: null,
      modelBackend: null,
      schemaVersion: SetupStatus.currentSchemaVersion,
    );
    await saveStatus(updated);
    return updated;
  }

  Future<SetupStatus> completeWithHealth({
    required int importedSamples,
    DateTime? lastBackfillAt,
  }) async {
    final status = await loadStatus();
    final now = _nowProvider();
    final updated = SetupStatus(
      completed: false,
      completedAt: null,
      profileValidatedAt: status.profileValidatedAt,
      modelValidatedAt: status.modelValidatedAt,
      healthValidatedAt: now,
      healthEnabled: true,
      healthLastBackfillAt: lastBackfillAt,
      healthImportedSamples: importedSamples,
      modelRuntimeProfile: status.modelRuntimeProfile,
      modelBackend: status.modelBackend,
      schemaVersion: SetupStatus.currentSchemaVersion,
    ).withDerivedCompletion(completedAtOverride: now);
    await saveStatus(updated);
    return updated;
  }

  Future<SetupStatus> completeWithoutHealth() async {
    final status = await loadStatus();
    final now = _nowProvider();
    final updated = SetupStatus(
      completed: false,
      completedAt: null,
      profileValidatedAt: status.profileValidatedAt,
      modelValidatedAt: status.modelValidatedAt,
      healthValidatedAt: now,
      healthEnabled: false,
      healthImportedSamples: 0,
      modelRuntimeProfile: status.modelRuntimeProfile,
      modelBackend: status.modelBackend,
      schemaVersion: SetupStatus.currentSchemaVersion,
    ).withDerivedCompletion(completedAtOverride: now);
    await saveStatus(updated);
    return updated;
  }

  Future<void> clearStatus() {
    return _repository.deleteAppSetting(setupStatusKey);
  }
}
