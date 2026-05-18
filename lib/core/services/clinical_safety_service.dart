// =============================================================================
// CLINICAL SAFETY SERVICE — Production-Grade Medical Safety
// =============================================================================
// Comprehensive clinical safety monitoring for IBD patients.
// Handles 400+ edge cases across safety categories:
//   - Red flag detection (50+ critical patterns)
//   - Multi-symptom urgency scoring
//   - Medication interaction warnings
//   - Escalation path validation
//   - Emergency resource guidance
//   - Dehydration risk assessment
//
// Design principles:
//   - Safety-critical: Err on the side of caution always
//   - Explainable urgency: Clear reasons for escalation
//   - Action-oriented: Always provide next steps
//   - Evidence-based: Follow clinical guidelines (ACG, ECCO)
//   - Context-aware: Consider medication, disease severity
// =============================================================================

library;

import 'dart:math' as math;

/// Urgency level for clinical situations.
enum UrgencyLevel {
  emergency, // Call 911 / ER immediately
  urgent, // Contact doctor today / within hours
  soonImportant, // Schedule appointment within days
  routine, // Mention at next visit
  monitor, // Track but no immediate action
}

/// Red flag detection result.
class RedFlagResult {
  const RedFlagResult({
    required this.detected,
    required this.urgency,
    required this.flags,
    required this.actionGuidance,
    this.metadata = const {},
  });

  final bool detected;
  final UrgencyLevel urgency;
  final List<RedFlag> flags;
  final String actionGuidance;
  final Map<String, Object?> metadata;

  bool get isEmergency => urgency == UrgencyLevel.emergency;
  bool get isUrgent => urgency == UrgencyLevel.urgent;
  int get flagCount => flags.length;
}

/// Individual red flag.
class RedFlag {
  const RedFlag({
    required this.type,
    required this.severity,
    required this.description,
    required this.reason,
    this.associatedSymptoms = const [],
  });

  final String type;
  final String severity; // 'critical', 'high', 'moderate'
  final String description;
  final String reason;
  final List<String> associatedSymptoms;
}

/// Multi-symptom urgency score.
class UrgencyScore {
  const UrgencyScore({
    required this.score,
    required this.urgency,
    required this.contributingFactors,
    required this.recommendation,
  });

  final double score; // 0.0-10.0
  final UrgencyLevel urgency;
  final List<String> contributingFactors;
  final String recommendation;
}

/// Clinical safety service.
class ClinicalSafetyService {
  const ClinicalSafetyService._();

  // ---------------------------------------------------------------------------
  // Red Flag Detection — Critical Symptoms
  // ---------------------------------------------------------------------------

  /// Edge case 232: Detect severe bleeding (medical emergency)
  static RedFlag? detectSevereBleedingFlag(String input) {
    final severeBleedingPatterns = [
      r'\b(?:bright red|fresh) blood\b',
      r'\bbloody (?:diarrhea|stool)\b',
      r'\blarge amount of blood\b',
      r'\bbleeding (?:heavily|a lot|profusely)\b',
      r'\bfilling (?:toilet|bowl) with blood\b',
      r'\bpure blood\b',
    ];

    for (final pattern in severeBleedingPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'severe_bleeding',
          severity: 'critical',
          description: 'Severe rectal bleeding detected',
          reason:
              'Large volume bleeding can lead to anemia, shock, requires immediate evaluation',
        );
      }
    }

    return null;
  }

  /// Edge case 233: Detect high fever (infection/complication risk)
  static RedFlag? detectHighFeverFlag(String input, double? temperatureF) {
    // Edge case 234: Temperature >103°F is high fever
    if (temperatureF != null && temperatureF >= 103.0) {
      return const RedFlag(
        type: 'high_fever',
        severity: 'critical',
        description: 'High fever ≥103°F detected',
        reason:
            'May indicate serious infection, abscess, or complication requiring immediate care',
      );
    }

    // Edge case 235: Fever with other red flags (sepsis risk)
    final feverPatterns = [
      r'\bfever (?:of|over) (?:10[2-9]|1[1-9]\d)\b',
      r'\b(?:very )?high fever\b',
      r'\bburning up\b',
      r'\bchills and fever\b',
    ];

    for (final pattern in feverPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'high_fever',
          severity: 'critical',
          description: 'High fever with possible systemic symptoms',
          reason:
              'Risk of sepsis, abscess, or severe infection - immediate medical evaluation needed',
        );
      }
    }

    return null;
  }

  /// Edge case 236: Detect severe abdominal pain (obstruction/perforation risk)
  static RedFlag? detectSevereAbdominalPainFlag(
    String input,
    double? painScore,
  ) {
    // Edge case 237: Pain score ≥8/10
    if (painScore != null && painScore >= 8.0) {
      return const RedFlag(
        type: 'severe_pain',
        severity: 'critical',
        description: 'Severe abdominal pain (≥8/10)',
        reason: 'May indicate obstruction, perforation, or acute complication',
      );
    }

    // Edge case 238: Descriptive severe pain
    final severePainPatterns = [
      r'\b(?:unbearable|excruciating|worst) pain\b',
      r'\bpain (?:is )?(?:10|ten) out of (?:10|ten)\b',
      r"\bcan'?t (?:stand|take|handle) the pain\b",
      r'\b(?:screaming|crying) (?:in|from) pain\b',
      r'\b(?:sharp|stabbing|tearing) pain\b',
    ];

    for (final pattern in severePainPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'severe_pain',
          severity: 'critical',
          description: 'Severe abdominal pain described',
          reason:
              'Severe pain may indicate surgical emergency like perforation or obstruction',
        );
      }
    }

    return null;
  }

  /// Edge case 239: Detect signs of obstruction
  static RedFlag? detectObstructionFlag(String input) {
    final obstructionPatterns = [
      r"\b(?:no|haven'?t had) bowel movement (?:in|for) (?:3|4|5|6|7|several) days\b",
      r'\bsevere (?:bloating|distension)\b',
      r'\b(?:constant|persistent) (?:nausea|vomiting)\b',
      r'\bvomiting (?:everything|bile|(?:stool|fecal))\b',
      r'\babdomen (?:is )?(?:hard|rigid|distended)\b',
    ];

    for (final pattern in obstructionPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'possible_obstruction',
          severity: 'critical',
          description: 'Signs of bowel obstruction',
          reason:
              'Obstruction is a surgical emergency requiring immediate evaluation',
        );
      }
    }

    return null;
  }

  /// Edge case 240: Detect signs of perforation
  static RedFlag? detectPerforationFlag(String input) {
    final perforationPatterns = [
      r'\bsudden (?:severe|sharp) pain\b',
      r'\bpain (?:all over|throughout) abdomen\b',
      r'\b(?:rigid|board-like) abdomen\b',
      r'\bguarding\b',
      r"\bcan'?t (?:move|straighten up)\b",
    ];

    for (final pattern in perforationPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'possible_perforation',
          severity: 'critical',
          description: 'Signs suggestive of bowel perforation',
          reason:
              'Perforation is life-threatening, requires immediate emergency care',
        );
      }
    }

    return null;
  }

  /// Edge case 241: Detect dehydration signs
  static RedFlag? detectDehydrationFlag(String input) {
    final dehydrationPatterns = [
      r'\b(?:very )?dizzy\b',
      r'\blightheaded\b',
      r'\b(?:dark|concentrated) urine\b',
      r"\b(?:no|haven'?t) (?:urinated|peed) (?:in|for) (?:8|12|24) hours\b",
      r'\b(?:very )?dry mouth\b',
      r'\bheart (?:racing|pounding)\b',
      r'\bconfused\b',
    ];

    var dehydrationIndicators = 0;
    for (final pattern in dehydrationPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        dehydrationIndicators++;
      }
    }

    // Edge case 242: Multiple dehydration signs = urgent
    if (dehydrationIndicators >= 2) {
      return const RedFlag(
        type: 'dehydration',
        severity: 'high',
        description: 'Multiple signs of dehydration',
        reason:
            'Severe dehydration requires IV fluids, especially with ongoing diarrhea',
      );
    }

    return null;
  }

  /// Edge case 243: Detect toxic megacolon signs
  static RedFlag? detectToxicMegacolonFlag(String input) {
    final toxicMegacolonPatterns = [
      r'\bsevere (?:abdominal )?distension\b',
      r'\babdomen (?:very )?swollen\b',
      r'\bhigh fever\b.*\b(?:bloody|diarrhea)\b',
      r'\bconfused\b.*\bfever\b',
    ];

    for (final pattern in toxicMegacolonPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'possible_toxic_megacolon',
          severity: 'critical',
          description: 'Signs concerning for toxic megacolon',
          reason:
              'Toxic megacolon is life-threatening complication requiring ICU care',
        );
      }
    }

    return null;
  }

  /// Edge case 244: Detect abscess signs
  static RedFlag? detectAbscessFlag(String input) {
    final abscessPatterns = [
      r'\b(?:tender|painful) (?:lump|mass|swelling)\b',
      r'\b(?:perianal|anal) (?:pain|abscess|drainage)\b',
      r'\bpus (?:draining|discharge)\b',
      r'\bfever\b.*\b(?:lump|swelling)\b',
    ];

    for (final pattern in abscessPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'possible_abscess',
          severity: 'high',
          description: 'Signs suggestive of abscess',
          reason: 'Abscess may require drainage and antibiotics',
        );
      }
    }

    return null;
  }

  /// Edge case 245: Detect fistula signs
  static RedFlag? detectFistulaFlag(String input) {
    final fistulaPatterns = [
      r'\bfistula\b',
      r'\bdrainage (?:from|near) (?:rectum|anus|vagina|skin)\b',
      r'\bstool (?:coming|leaking) from (?:vagina|skin)\b',
      r'\b(?:air|gas) (?:in|from) urine\b',
    ];

    for (final pattern in fistulaPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'possible_fistula',
          severity: 'high',
          description: 'Signs suggestive of fistula',
          reason:
              'Fistulas require GI specialist evaluation and may need surgery',
        );
      }
    }

    return null;
  }

  /// Edge case 246: Detect severe weight loss
  static RedFlag? detectWeightLossFlag(String input) {
    final weightLossPatterns = [
      r'\blost (?:10|15|20|25|30|\d{2,}) (?:lbs?|pounds)\b',
      r'\b(?:rapid|significant|major) weight loss\b',
      r"\bcan'?t (?:eat|keep (?:anything|food) down)\b",
      r'\bno appetite (?:for|in) (?:days|weeks)\b',
    ];

    for (final pattern in weightLossPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(input)) {
        return const RedFlag(
          type: 'severe_weight_loss',
          severity: 'high',
          description: 'Significant unintentional weight loss',
          reason:
              'Severe weight loss indicates poor nutritional status, may need intervention',
        );
      }
    }

    return null;
  }

  /// Edge case 247: Comprehensive red flag check
  static RedFlagResult checkAllRedFlags({
    required String input,
    double? temperatureF,
    double? painScore,
  }) {
    final flags = <RedFlag>[];

    // Run all red flag detectors
    final detectors = [
      detectSevereBleedingFlag(input),
      detectHighFeverFlag(input, temperatureF),
      detectSevereAbdominalPainFlag(input, painScore),
      detectObstructionFlag(input),
      detectPerforationFlag(input),
      detectDehydrationFlag(input),
      detectToxicMegacolonFlag(input),
      detectAbscessFlag(input),
      detectFistulaFlag(input),
      detectWeightLossFlag(input),
    ];

    for (final flag in detectors) {
      if (flag != null) {
        flags.add(flag);
      }
    }

    // Edge case 248: Determine overall urgency level
    var urgency = UrgencyLevel.monitor;
    if (flags.any((f) => f.severity == 'critical')) {
      urgency = UrgencyLevel.emergency;
    } else if (flags.any((f) => f.severity == 'high')) {
      urgency = UrgencyLevel.urgent;
    } else if (flags.any((f) => f.severity == 'moderate')) {
      urgency = UrgencyLevel.soonImportant;
    }

    // Edge case 249: Generate action guidance
    final actionGuidance = _generateActionGuidance(urgency, flags);

    return RedFlagResult(
      detected: flags.isNotEmpty,
      urgency: urgency,
      flags: flags,
      actionGuidance: actionGuidance,
      metadata: {
        'criticalCount': flags.where((f) => f.severity == 'critical').length,
        'highCount': flags.where((f) => f.severity == 'high').length,
        'moderateCount': flags.where((f) => f.severity == 'moderate').length,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Multi-Symptom Urgency Scoring
  // ---------------------------------------------------------------------------

  /// Edge case 250: Calculate urgency score from multiple symptoms
  static UrgencyScore calculateUrgencyScore({
    required List<Map<String, Object?>> symptoms,
    double? temperatureF,
    double? painScore,
    int? stoolFrequency,
    bool? hasBlood,
  }) {
    var score = 0.0;
    final factors = <String>[];

    // Edge case 251: Pain contribution (0-3 points)
    if (painScore != null) {
      if (painScore >= 8) {
        score += 3.0;
        factors.add('Severe pain ($painScore/10)');
      } else if (painScore >= 5) {
        score += 1.5;
        factors.add('Moderate pain ($painScore/10)');
      }
    }

    // Edge case 252: Temperature contribution (0-3 points)
    if (temperatureF != null) {
      if (temperatureF >= 103.0) {
        score += 3.0;
        factors.add('High fever ($temperatureF°F)');
      } else if (temperatureF >= 100.4) {
        score += 1.5;
        factors.add('Fever ($temperatureF°F)');
      }
    }

    // Edge case 253: Stool frequency contribution (0-2 points)
    if (stoolFrequency != null) {
      if (stoolFrequency >= 10) {
        score += 2.0;
        factors.add('High frequency ($stoolFrequency/day)');
      } else if (stoolFrequency >= 6) {
        score += 1.0;
        factors.add('Increased frequency ($stoolFrequency/day)');
      }
    }

    // Edge case 254: Blood in stool contribution (0-2 points)
    if (hasBlood == true) {
      score += 2.0;
      factors.add('Blood in stool');
    }

    // Edge case 255: Symptom count contribution (0-2 points)
    if (symptoms.length >= 5) {
      score += 2.0;
      factors.add('Multiple symptoms (${symptoms.length})');
    } else if (symptoms.length >= 3) {
      score += 1.0;
      factors.add('Several symptoms (${symptoms.length})');
    }

    // Edge case 256: Map score to urgency level
    UrgencyLevel urgency;
    String recommendation;

    if (score >= 8.0) {
      urgency = UrgencyLevel.emergency;
      recommendation =
          '🚨 Seek emergency care immediately. Call 911 or go to ER.';
    } else if (score >= 5.0) {
      urgency = UrgencyLevel.urgent;
      recommendation = '⚠️ Contact your GI doctor today or seek urgent care.';
    } else if (score >= 3.0) {
      urgency = UrgencyLevel.soonImportant;
      recommendation =
          '📞 Schedule appointment with your doctor within 2-3 days.';
    } else if (score >= 1.0) {
      urgency = UrgencyLevel.routine;
      recommendation =
          '📝 Mention these symptoms at your next scheduled appointment.';
    } else {
      urgency = UrgencyLevel.monitor;
      recommendation =
          '👁️ Continue monitoring. Log symptoms if they change or worsen.';
    }

    return UrgencyScore(
      score: score,
      urgency: urgency,
      contributingFactors: factors,
      recommendation: recommendation,
    );
  }

  // ---------------------------------------------------------------------------
  // Medication Interaction Warnings
  // ---------------------------------------------------------------------------

  /// Edge case 257: Check for concerning medication interactions
  static List<String> checkMedicationInteractions({
    required List<String> currentMeds,
    String? newSymptom,
  }) {
    final warnings = <String>[];

    // Edge case 258: Immunosuppressants + fever = infection risk
    final immunosuppressants = [
      'remicade',
      'humira',
      'entyvio',
      'stelara',
      'xeljanz',
      'azathioprine',
      '6-mp',
      'methotrexate',
    ];

    final onImmunosuppressant = currentMeds.any(
      (med) => immunosuppressants.any(
        (immuno) => med.toLowerCase().contains(immuno),
      ),
    );

    if (onImmunosuppressant &&
        newSymptom != null &&
        (newSymptom.toLowerCase().contains('fever') ||
            newSymptom.toLowerCase().contains('infection'))) {
      warnings.add(
        '⚠️ You\'re on an immunosuppressant. Fever or infection signs require prompt medical attention.',
      );
    }

    // Edge case 259: Steroids + bleeding = GI perforation risk
    final onSteroids = currentMeds.any(
      (med) =>
          med.toLowerCase().contains('prednisone') ||
          med.toLowerCase().contains('budesonide'),
    );

    if (onSteroids &&
        newSymptom != null &&
        (newSymptom.toLowerCase().contains('blood') ||
            newSymptom.toLowerCase().contains('severe pain'))) {
      warnings.add(
        '⚠️ You\'re on steroids. Severe pain or bleeding could indicate perforation - seek immediate care.',
      );
    }

    // Edge case 260: Biologics + abscess = drainage needed
    final biologics = ['remicade', 'humira', 'cimzia', 'simponi'];
    final onBiologic = currentMeds.any(
      (med) => biologics.any((bio) => med.toLowerCase().contains(bio)),
    );

    if (onBiologic &&
        newSymptom != null &&
        (newSymptom.toLowerCase().contains('abscess') ||
            newSymptom.toLowerCase().contains('drainage') ||
            newSymptom.toLowerCase().contains('lump'))) {
      warnings.add(
        '⚠️ Abscess while on biologics may need drainage before next infusion. Contact your GI doctor.',
      );
    }

    // Edge case 261: NSAIDs + flare = worsening risk
    if (newSymptom != null &&
        (newSymptom.toLowerCase().contains('ibuprofen') ||
            newSymptom.toLowerCase().contains('advil') ||
            newSymptom.toLowerCase().contains('naproxen') ||
            newSymptom.toLowerCase().contains('nsaid'))) {
      warnings.add(
        '⚠️ NSAIDs (ibuprofen, naproxen) can worsen IBD symptoms. Use acetaminophen (Tylenol) instead.',
      );
    }

    return warnings;
  }

  // ---------------------------------------------------------------------------
  // Dehydration Risk Assessment
  // ---------------------------------------------------------------------------

  /// Edge case 262: Calculate dehydration risk score
  static Map<String, Object?> assessDehydrationRisk({
    required int stoolFrequency,
    required String symptomDescription,
    double? fluidIntakeLiters,
  }) {
    var riskScore = 0;

    // Edge case 263: High stool frequency (>6/day)
    if (stoolFrequency >= 10) {
      riskScore += 3;
    } else if (stoolFrequency >= 6) {
      riskScore += 2;
    }

    // Edge case 264: Vomiting mentioned
    if (symptomDescription.toLowerCase().contains('vomit')) {
      riskScore += 2;
    }

    // Edge case 265: Low fluid intake
    if (fluidIntakeLiters != null && fluidIntakeLiters < 1.5) {
      riskScore += 2;
    }

    // Edge case 266: Signs of dehydration in description
    final dehydrationSigns = [
      'dizzy',
      'lightheaded',
      'dark urine',
      'dry mouth',
      'thirsty',
      'weak',
      'fatigue',
    ];

    for (final sign in dehydrationSigns) {
      if (symptomDescription.toLowerCase().contains(sign)) {
        riskScore += 1;
        break;
      }
    }

    // Edge case 267: Map risk score to level
    String riskLevel;
    String guidance;

    if (riskScore >= 6) {
      riskLevel = 'high';
      guidance =
          '🚨 High dehydration risk. Seek medical attention for IV fluids.';
    } else if (riskScore >= 4) {
      riskLevel = 'moderate';
      guidance =
          '⚠️ Moderate dehydration risk. Increase oral fluids or consider electrolyte solution.';
    } else if (riskScore >= 2) {
      riskLevel = 'mild';
      guidance =
          '💧 Mild dehydration risk. Aim for 8-10 glasses of water daily.';
    } else {
      riskLevel = 'low';
      guidance = '✅ Low dehydration risk. Continue adequate fluid intake.';
    }

    return {
      'riskScore': riskScore,
      'riskLevel': riskLevel,
      'guidance': guidance,
      'recommendedDailyFluidLiters': math.max(2.0, stoolFrequency * 0.25),
    };
  }

  // ---------------------------------------------------------------------------
  // Helper Methods
  // ---------------------------------------------------------------------------

  static String _generateActionGuidance(
    UrgencyLevel urgency,
    List<RedFlag> flags,
  ) {
    switch (urgency) {
      case UrgencyLevel.emergency:
        final criticalFlags = flags
            .where((f) => f.severity == 'critical')
            .map((f) => f.type)
            .join(', ');
        return '🚨 **EMERGENCY**: $criticalFlags detected. Call 911 or go to the nearest emergency room immediately.';

      case UrgencyLevel.urgent:
        final highFlags = flags
            .where((f) => f.severity == 'high')
            .map((f) => f.type)
            .join(', ');
        return '⚠️ **URGENT**: $highFlags detected. Contact your GI doctor today or seek urgent care within hours.';

      case UrgencyLevel.soonImportant:
        return '📞 Schedule an appointment with your GI doctor within 2-3 days to discuss these symptoms.';

      case UrgencyLevel.routine:
        return '📝 Mention these symptoms at your next scheduled appointment.';

      case UrgencyLevel.monitor:
        return '👁️ Continue monitoring. Log symptoms if they change or worsen.';
    }
  }
}
