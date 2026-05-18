import '../database/wearable_sample_repository.dart';

class Pro2ScoreService {
  const Pro2ScoreService._();

  static const cdV1Pain7Stool1 = Pro2SurveyRecord.cdV1Pain7Stool1;
  static const cdV2Pain2Stool1 = Pro2SurveyRecord.cdV2Pain2Stool1;
  static const ucV1BleedingStool = Pro2SurveyRecord.ucV1BleedingStool;
  static const defaultCdScoreVersion = cdV2Pain2Stool1;

  static double computeCdScore({
    required int abdominalPain,
    required int stoolFrequency,
    required String scoreVersion,
  }) {
    switch (scoreVersion) {
      case cdV2Pain2Stool1:
        return (abdominalPain * 2 + stoolFrequency).toDouble();
      case cdV1Pain7Stool1:
      default:
        return (abdominalPain * 7 + stoolFrequency).toDouble();
    }
  }

  static double computeUcScore({
    required int rectalBleeding,
    required int stoolFrequency,
  }) =>
      (rectalBleeding + stoolFrequency).toDouble();

  static String describeCdSeverity({
    required double score,
    required String scoreVersion,
  }) {
    switch (scoreVersion) {
      case cdV2Pain2Stool1:
        if (score < 8) {
          return 'Remission';
        }
        if (score >= 9) {
          return 'Severe flare';
        }
        return 'Mild flare';
      case cdV1Pain7Stool1:
      default:
        if (score < 8) {
          return 'Remission';
        }
        if (score < 16) {
          return 'Mild flare';
        }
        return 'Severe flare';
    }
  }

  static String describeUcSeverity({
    required double score,
    required int rectalBleeding,
    required int stoolFrequency,
  }) {
    if (score <= 1 && rectalBleeding == 0 && stoolFrequency <= 1) {
      return 'Remission';
    }
    if (score <= 3) {
      return 'Mild flare';
    }
    return 'Severe flare';
  }

  static bool isFlareSurvey(Pro2SurveyRecord survey) {
    if (survey.diseaseType == 'CD') {
      return _cdScoreFromSurvey(survey) >= 8;
    }
    if (survey.pro2Score > 1) return true;
    if ((survey.ucRectalBleeding ?? 0) > 0) return true;
    if ((survey.ucStoolFrequency ?? 0) > 1) return true;
    return false;
  }

  static double _cdScoreFromSurvey(Pro2SurveyRecord survey) {
    final pain = survey.cdAbdominalPain;
    final stool = survey.cdStoolFrequency;
    if (pain == null || stool == null) {
      return survey.pro2Score;
    }
    return computeCdScore(
      abdominalPain: pain,
      stoolFrequency: stool,
      scoreVersion: survey.scoreVersion,
    );
  }
}
