import '../database/wearable_sample_repository.dart';

class MedicationEntry {
  const MedicationEntry({
    required this.name,
    this.dose,
    this.frequency,
    this.startDate,
  });

  final String name;
  final String? dose;
  final String? frequency;
  final String? startDate;

  Map<String, Object?> toJson() => {
        'name': name,
        'dose': dose,
        'frequency': frequency,
        'start_date': startDate,
      };

  factory MedicationEntry.fromJson(Map<String, Object?> json) {
    return MedicationEntry(
      name: (json['name'] as String?)?.trim() ?? '',
      dose: (json['dose'] as String?)?.trim(),
      frequency: (json['frequency'] as String?)?.trim(),
      startDate: json['start_date'] as String?,
    );
  }
}

class UserProfile {
  const UserProfile({
    this.dateOfBirth,
    this.biologicalSex,
    this.heightCm,
    this.weightKg,
    this.heightUnitPreference = 'cm',
    this.weightUnitPreference = 'kg',
    this.diseaseType,
    this.cdDiseaseLocation,
    this.cdDiseaseBehavior,
    this.cdPerianalInvolvement,
    this.ucDiseaseExtent,
    this.diagnosisYear,
    this.hadSurgery,
    this.surgeryType,
    this.surgeryYear,
    this.medications = const [],
    this.otherConditions = const [],
    this.deviceType,
    this.watchSeries,
  });

  static const empty = UserProfile();

  final String? dateOfBirth;
  final String? biologicalSex;
  final double? heightCm;
  final double? weightKg;
  final String heightUnitPreference;
  final String weightUnitPreference;
  final String? diseaseType;
  final String? cdDiseaseLocation;
  final String? cdDiseaseBehavior;
  final bool? cdPerianalInvolvement;
  final String? ucDiseaseExtent;
  final int? diagnosisYear;
  final bool? hadSurgery;
  final String? surgeryType;
  final int? surgeryYear;
  final List<MedicationEntry> medications;
  final List<String> otherConditions;
  final String? deviceType;
  final String? watchSeries;

  bool get hasProfileData =>
      dateOfBirth != null ||
      biologicalSex != null ||
      heightCm != null ||
      weightKg != null ||
      diseaseType != null ||
      diagnosisYear != null ||
      medications.isNotEmpty ||
      otherConditions.isNotEmpty ||
      deviceType != null ||
      watchSeries != null;

  bool get isCrohns => diseaseType == 'CD';
  bool get isColitis => diseaseType == 'UC';

  double? get bmi {
    final heightMeters = (heightCm ?? 0) / 100.0;
    if (heightMeters <= 0 || (weightKg ?? 0) <= 0) {
      return null;
    }
    return weightKg! / (heightMeters * heightMeters);
  }

  int? ageAt(DateTime now) {
    if (dateOfBirth == null) {
      return null;
    }
    final dob = DateTime.tryParse('${dateOfBirth!}T00:00:00Z');
    if (dob == null) {
      return null;
    }

    var age = now.year - dob.year;
    final birthdayPassed =
        now.month > dob.month || (now.month == dob.month && now.day >= dob.day);
    if (!birthdayPassed) {
      age -= 1;
    }
    return age >= 0 ? age : null;
  }

  UserProfile copyWith({
    String? dateOfBirth,
    String? biologicalSex,
    double? heightCm,
    double? weightKg,
    String? heightUnitPreference,
    String? weightUnitPreference,
    String? diseaseType,
    String? cdDiseaseLocation,
    String? cdDiseaseBehavior,
    bool? cdPerianalInvolvement,
    String? ucDiseaseExtent,
    int? diagnosisYear,
    bool? hadSurgery,
    String? surgeryType,
    int? surgeryYear,
    List<MedicationEntry>? medications,
    List<String>? otherConditions,
    String? deviceType,
    String? watchSeries,
  }) {
    return UserProfile(
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      biologicalSex: biologicalSex ?? this.biologicalSex,
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
      heightUnitPreference: heightUnitPreference ?? this.heightUnitPreference,
      weightUnitPreference: weightUnitPreference ?? this.weightUnitPreference,
      diseaseType: diseaseType ?? this.diseaseType,
      cdDiseaseLocation: cdDiseaseLocation ?? this.cdDiseaseLocation,
      cdDiseaseBehavior: cdDiseaseBehavior ?? this.cdDiseaseBehavior,
      cdPerianalInvolvement:
          cdPerianalInvolvement ?? this.cdPerianalInvolvement,
      ucDiseaseExtent: ucDiseaseExtent ?? this.ucDiseaseExtent,
      diagnosisYear: diagnosisYear ?? this.diagnosisYear,
      hadSurgery: hadSurgery ?? this.hadSurgery,
      surgeryType: surgeryType ?? this.surgeryType,
      surgeryYear: surgeryYear ?? this.surgeryYear,
      medications: medications ?? this.medications,
      otherConditions: otherConditions ?? this.otherConditions,
      deviceType: deviceType ?? this.deviceType,
      watchSeries: watchSeries ?? this.watchSeries,
    );
  }

  Map<String, Object?> toJson() => {
        'date_of_birth': dateOfBirth,
        'biological_sex': biologicalSex,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'height_unit_preference': heightUnitPreference,
        'weight_unit_preference': weightUnitPreference,
        'disease_type': diseaseType,
        'cd_disease_location': cdDiseaseLocation,
        'cd_disease_behavior': cdDiseaseBehavior,
        'cd_perianal_involvement': cdPerianalInvolvement,
        'uc_disease_extent': ucDiseaseExtent,
        'diagnosis_year': diagnosisYear,
        'had_surgery': hadSurgery,
        'surgery_type': surgeryType,
        'surgery_year': surgeryYear,
        'medications':
            medications.map((item) => item.toJson()).toList(growable: false),
        'other_conditions': otherConditions,
        'device_type': deviceType,
        'watch_series': watchSeries,
      };

  factory UserProfile.fromJson(Map<String, Object?> json) {
    final medicationsJson = json['medications'];
    final conditionsJson = json['other_conditions'];
    return UserProfile(
      dateOfBirth: json['date_of_birth'] as String?,
      biologicalSex: json['biological_sex'] as String?,
      heightCm: (json['height_cm'] as num?)?.toDouble(),
      weightKg: (json['weight_kg'] as num?)?.toDouble(),
      heightUnitPreference: (json['height_unit_preference'] as String?) ?? 'cm',
      weightUnitPreference: (json['weight_unit_preference'] as String?) ?? 'kg',
      diseaseType: json['disease_type'] as String?,
      cdDiseaseLocation: json['cd_disease_location'] as String?,
      cdDiseaseBehavior: json['cd_disease_behavior'] as String?,
      cdPerianalInvolvement: json['cd_perianal_involvement'] as bool?,
      ucDiseaseExtent: json['uc_disease_extent'] as String?,
      diagnosisYear: (json['diagnosis_year'] as num?)?.toInt(),
      hadSurgery: json['had_surgery'] as bool?,
      surgeryType: json['surgery_type'] as String?,
      surgeryYear: (json['surgery_year'] as num?)?.toInt(),
      medications: medicationsJson is List
          ? medicationsJson
              .whereType<Map>()
              .map(
                (item) =>
                    MedicationEntry.fromJson(Map<String, Object?>.from(item)),
              )
              .where((item) => item.name.isNotEmpty)
              .toList(growable: false)
          : const [],
      otherConditions: conditionsJson is List
          ? conditionsJson.whereType<String>().toList(growable: false)
          : const [],
      deviceType: json['device_type'] as String?,
      watchSeries: json['watch_series'] as String?,
    );
  }
}

class UserProfileCovariates {
  const UserProfileCovariates({
    this.age,
    this.sexMale,
    this.bmi,
    this.diseaseCd,
  });

  final int? age;
  final bool? sexMale;
  final double? bmi;
  final bool? diseaseCd;

  Map<String, Object?> toFeatureJson() => {
        'user_age': age,
        'user_sex_male': sexMale == null ? null : (sexMale! ? 1 : 0),
        'user_bmi': bmi,
        'user_disease_cd': diseaseCd == null ? null : (diseaseCd! ? 1 : 0),
      };

  Map<String, Object?> toGroundedSummaryJson() => {
        'age': age,
        'biological_sex':
            sexMale == null ? null : (sexMale! ? 'male' : 'female_or_other'),
        'bmi': bmi == null ? null : double.parse(bmi!.toStringAsFixed(1)),
        'disease_type': diseaseCd == null ? null : (diseaseCd! ? 'CD' : 'UC'),
      };
}

class ProfileService {
  ProfileService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static const profileKey = 'user_profile';

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  Future<UserProfile> loadProfile() async {
    final json = await _repository.getAppSettingMap(profileKey);
    if (json == null) {
      return UserProfile.empty;
    }
    return UserProfile.fromJson(json);
  }

  Future<void> saveProfile(UserProfile profile) {
    return _repository.upsertAppSettingJson(
      key: profileKey,
      value: profile.toJson(),
    );
  }

  Future<void> clearProfile() {
    return _repository.deleteAppSetting(profileKey);
  }

  Future<UserProfileCovariates> getCovariates() async {
    final profile = await loadProfile();
    return UserProfileCovariates(
      age: profile.ageAt(_nowProvider()),
      sexMale: profile.biologicalSex == null
          ? null
          : profile.biologicalSex == 'male'
              ? true
              : false,
      bmi: profile.bmi,
      diseaseCd:
          profile.diseaseType == null ? null : profile.diseaseType == 'CD',
    );
  }

  Future<Map<String, Object?>> getGroundedSummary() async {
    final profile = await loadProfile();
    final covariates = await getCovariates();
    return {
      'has_profile': profile.hasProfileData,
      // disease_type carries the full string ('CD', 'UC', 'IC', 'IBS') for
      // prompt branching. covariates.disease_type retains the legacy boolean
      // form for backwards compatibility with the Mount-Sinai model pathway.
      'disease_type': profile.diseaseType,
      'covariates': covariates.toGroundedSummaryJson(),
      'device_type': profile.deviceType,
      'watch_series': profile.watchSeries,
      'diagnosis_year': profile.diagnosisYear,
      'medications': profile.medications
          .map((item) => item.toJson())
          .toList(growable: false),
      'other_conditions': profile.otherConditions,
    };
  }
}
