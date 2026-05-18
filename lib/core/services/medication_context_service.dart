import '../database/wearable_sample_repository.dart';

class MedicationContextService {
  MedicationContextService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  Future<int> logMedicationEvent({
    required DateTime loggedAt,
    required String status,
    String? medicationName,
    String? dose,
    String source = 'manual',
  }) {
    final normalizedStatus =
        status == 'skipped' ? 'medication_skipped' : 'medication_taken';
    return _repository.upsertIntakeEvent(
      IntakeEventRecord(
        eventType: normalizedStatus,
        loggedAt: loggedAt.toUtc(),
        dateLocal: _dateOnly(loggedAt.toLocal()),
        source: source,
        confidence: source == 'manual' ? 1 : 0.8,
        notes: medicationName,
        metadataJson: {
          if (medicationName != null) 'medication_name': medicationName,
          if (dose != null) 'dose': dose,
          'status': status,
        },
        createdAt: _nowProvider(),
      ),
    );
  }

  String _dateOnly(DateTime dateTime) {
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    return '${dateTime.year}-$month-$day';
  }
}
