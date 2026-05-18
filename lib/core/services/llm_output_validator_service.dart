// =============================================================================
// LLM OUTPUT VALIDATOR SERVICE — Production-Grade Response Validation
// =============================================================================
// Comprehensive validation of LLM outputs for safety, quality, and correctness.
// Handles 300+ edge cases across validation categories:
//   - Hallucination detection patterns
//   - Safety boundary enforcement
//   - Format validation (markdown, structure)
//   - Content policy checks
//   - Response quality scoring
//   - Medical accuracy validation
//
// Design principles:
//   - Safety first: Block unsafe responses immediately
//   - Quality threshold: Minimum standards for all outputs
//   - Explainable rejections: Clear reasons for invalid responses
//   - Graceful degradation: Fallback to deterministic when LLM fails
//   - Continuous learning: Log patterns for model improvement
// =============================================================================

library;

import 'dart:math' as math;

/// Result of LLM output validation.
class ValidationResult {
  const ValidationResult({
    required this.isValid,
    required this.sanitizedOutput,
    this.quality = 0.0,
    this.violations = const [],
    this.warnings = const [],
    this.corrections = const [],
    this.metadata = const {},
  });

  final bool isValid;
  final String sanitizedOutput;
  final double quality; // 0.0-1.0
  final List<OutputViolation> violations;
  final List<String> warnings;
  final List<String> corrections;
  final Map<String, Object?> metadata;

  bool get hasViolations => violations.isNotEmpty;
  bool get hasWarnings => warnings.isNotEmpty;
  bool get needsCorrection => corrections.isNotEmpty;
  bool get isHighQuality => quality >= 0.8;
}

/// Output violation details.
class OutputViolation {
  const OutputViolation({
    required this.type,
    required this.severity,
    required this.description,
    this.location,
    this.suggestion,
  });

  final String type;
  final String severity; // 'critical', 'high', 'medium', 'low'
  final String description;
  final String? location;
  final String? suggestion;
}

/// LLM output validator service.
class LlmOutputValidatorService {
  const LlmOutputValidatorService._();

  // ---------------------------------------------------------------------------
  // Hallucination Detection
  // ---------------------------------------------------------------------------

  /// Edge case 190: Detect fabricated medical facts
  static List<OutputViolation> detectMedicalHallucinations(String output) {
    final violations = <OutputViolation>[];

    // Edge case 191: Definitive medical claims without evidence
    final definitiveClaims = [
      r'\bthis will cure\b',
      r'\bguaranteed to\b',
      r'\balways causes\b',
      r'\bnever occurs with\b',
      r'\b100% effective\b',
      r'\bcompletely safe\b',
      r'\bno side effects\b',
    ];

    for (final pattern in definitiveClaims) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(output)) {
        violations.add(
          OutputViolation(
            type: 'medical_hallucination',
            severity: 'critical',
            description:
                'Definitive medical claim without evidence: "$pattern"',
            suggestion:
                'Use qualified language like "may help", "can reduce", "typically"',
          ),
        );
      }
    }

    // Edge case 192: Specific medical dosages without disclaimer
    final dosagePattern = RegExp(
      r'\b(\d+)\s*(mg|mcg|g|ml|units?)\s+(?:of|per|daily|twice|three times)',
      caseSensitive: false,
    );

    if (dosagePattern.hasMatch(output) &&
        !output.toLowerCase().contains('consult') &&
        !output.toLowerCase().contains('doctor') &&
        !output.toLowerCase().contains('healthcare provider')) {
      violations.add(
        OutputViolation(
          type: 'medical_hallucination',
          severity: 'high',
          description:
              'Specific dosage without medical professional disclaimer',
          suggestion:
              'Add disclaimer: "Consult your healthcare provider for proper dosing"',
        ),
      );
    }

    // Edge case 193: References to non-existent studies
    final studyPattern = RegExp(
      r'\b(?:study|research|trial|published in)\s+(?:shows?|demonstrates?|proves?)',
      caseSensitive: false,
    );

    if (studyPattern.hasMatch(output) &&
        !output.contains('http') &&
        !RegExp(r'\d{4}').hasMatch(output)) {
      // No year cited
      violations.add(
        OutputViolation(
          type: 'medical_hallucination',
          severity: 'medium',
          description: 'Study reference without citation or year',
          suggestion: 'Either provide full citation or remove study reference',
        ),
      );
    }

    // Edge case 194: Fabricated medication names
    final suspiciousMedNames = [
      r'\b[A-Z][a-z]+ol\b(?!esterol)', // Ends in -ol but not cholesterol
      r'\b[A-Z][a-z]+ine\b(?!line)', // Ends in -ine suspiciously
      r'\b[A-Z][a-z]+mab\b', // Monoclonal antibodies
    ];

    for (final pattern in suspiciousMedNames) {
      final matches = RegExp(pattern).allMatches(output);
      for (final match in matches) {
        final word = match.group(0)!;
        // Check against known medications list would go here
        // For now, flag for review
        violations.add(
          OutputViolation(
            type: 'possible_hallucination',
            severity: 'low',
            description: 'Potential fabricated medication name: "$word"',
            location: word,
            suggestion: 'Verify medication name in reference database',
          ),
        );
      }
    }

    return violations;
  }

  /// Edge case 195: Detect contradictory statements
  static List<OutputViolation> detectContradictions(String output) {
    final violations = <OutputViolation>[];

    // Edge case 196: "Always" contradicts "Sometimes"
    final alwaysPattern = RegExp(r'\balways\b', caseSensitive: false);
    final sometimesPattern = RegExp(
      r'\b(?:sometimes|occasionally|may)\b',
      caseSensitive: false,
    );

    if (alwaysPattern.hasMatch(output) && sometimesPattern.hasMatch(output)) {
      violations.add(
        OutputViolation(
          type: 'contradiction',
          severity: 'medium',
          description:
              'Output contains both "always" and "sometimes/may" statements',
          suggestion: 'Choose consistent level of certainty',
        ),
      );
    }

    // Edge case 197: "Safe" contradicts "risk" or "danger"
    if (output.toLowerCase().contains('safe') &&
        (output.toLowerCase().contains('risk') ||
            output.toLowerCase().contains('danger'))) {
      violations.add(
        OutputViolation(
          type: 'contradiction',
          severity: 'high',
          description: 'Output claims both safety and risk',
          suggestion: 'Clarify the safety profile with specific context',
        ),
      );
    }

    // Edge case 198: Positive and negative sentiment about same topic
    final sentences = output.split(RegExp(r'[.!?]\s+'));
    for (var i = 0; i < sentences.length - 1; i++) {
      final sent1 = sentences[i].toLowerCase();
      final sent2 = sentences[i + 1].toLowerCase();

      final hasPositive1 = RegExp(
        r'\b(?:good|effective|helpful|beneficial)\b',
      ).hasMatch(sent1);
      final hasNegative1 = RegExp(
        r'\b(?:bad|ineffective|harmful|dangerous)\b',
      ).hasMatch(sent1);
      final hasPositive2 = RegExp(
        r'\b(?:good|effective|helpful|beneficial)\b',
      ).hasMatch(sent2);
      final hasNegative2 = RegExp(
        r'\b(?:bad|ineffective|harmful|dangerous)\b',
      ).hasMatch(sent2);

      if ((hasPositive1 && hasNegative2) || (hasNegative1 && hasPositive2)) {
        violations.add(
          OutputViolation(
            type: 'contradiction',
            severity: 'medium',
            description: 'Adjacent sentences have contradictory sentiment',
            location: 'Sentences $i-${i + 1}',
            suggestion: 'Clarify or add transition explaining the nuance',
          ),
        );
      }
    }

    return violations;
  }

  /// Edge case 199: Detect hallucinated data references
  static List<OutputViolation> detectFabricatedDataReferences(
    String output,
    Set<String> availableDataTypes,
  ) {
    final violations = <OutputViolation>[];

    // Edge case 200: References to data we don't have
    final dataReferences = {
      'your recent blood work': 'lab_results',
      'your colonoscopy': 'colonoscopy_report',
      'your biopsy': 'biopsy_results',
      'your CT scan': 'ct_scan',
      'your MRI': 'mri_results',
      'your x-ray': 'xray_results',
      'your genetic test': 'genetic_test',
    };

    for (final entry in dataReferences.entries) {
      if (output.toLowerCase().contains(entry.key) &&
          !availableDataTypes.contains(entry.value)) {
        violations.add(
          OutputViolation(
            type: 'fabricated_data_reference',
            severity: 'critical',
            description: 'References "${entry.key}" but no such data exists',
            suggestion: 'Remove reference or ask user to upload data',
          ),
        );
      }
    }

    // Edge case 201: Specific values that don't exist
    final valuePattern = RegExp(
      r'\byour (?:CRP|ESR|calprotectin|hemoglobin|ferritin) (?:is|was) (\d+(?:\.\d+)?)',
      caseSensitive: false,
    );

    if (valuePattern.hasMatch(output) &&
        !availableDataTypes.contains('lab_results')) {
      violations.add(
        OutputViolation(
          type: 'fabricated_lab_value',
          severity: 'critical',
          description: 'Cites specific lab values but no lab data available',
          suggestion:
              'Remove specific values or ask user to provide lab results',
        ),
      );
    }

    return violations;
  }

  // ---------------------------------------------------------------------------
  // Safety Boundary Enforcement
  // ---------------------------------------------------------------------------

  /// Edge case 202: Detect diagnostic language
  static List<OutputViolation> detectDiagnosticLanguage(String output) {
    final violations = <OutputViolation>[];

    // Edge case 203: Direct diagnosis statements
    final diagnosticPhrases = [
      r"\byou have (?:crohn'?s|colitis|ibd)\b",
      r'\byou are diagnosed with\b',
      r'\byour diagnosis is\b',
      r"\bthis is (?:definitely|certainly) (?:crohn'?s|colitis)\b",
      r'\byou (?:definitely|certainly) have\b',
    ];

    for (final pattern in diagnosticPhrases) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(output)) {
        violations.add(
          OutputViolation(
            type: 'diagnostic_language',
            severity: 'critical',
            description: 'Contains diagnostic language: "$pattern"',
            suggestion:
                'Replace with "symptoms suggest", "may indicate", "consistent with"',
          ),
        );
      }
    }

    // Edge case 204: Treatment recommendations without disclaimer
    final treatmentPhrases = [
      r'\byou should take\b',
      r'\byou need to start\b',
      r'\bi recommend taking\b',
      r'\bthe best treatment is\b',
      r'\byou must (?:take|stop|start)\b',
    ];

    for (final pattern in treatmentPhrases) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(output)) {
        violations.add(
          OutputViolation(
            type: 'treatment_recommendation',
            severity: 'critical',
            description: 'Direct treatment recommendation: "$pattern"',
            suggestion:
                'Replace with "discuss with your doctor", "ask your GI about"',
          ),
        );
      }
    }

    // Edge case 205: Medical emergencies without 911 reference
    final emergencyKeywords = [
      'perforation',
      'severe bleeding',
      'sepsis',
      'toxic megacolon',
      'high fever',
      'dehydration',
      'obstruction',
    ];

    var hasEmergency = false;
    var has911Reference = false;

    for (final keyword in emergencyKeywords) {
      if (output.toLowerCase().contains(keyword)) {
        hasEmergency = true;
        break;
      }
    }

    if (output.contains('911') ||
        output.toLowerCase().contains('emergency') ||
        output.toLowerCase().contains('call your doctor immediately')) {
      has911Reference = true;
    }

    if (hasEmergency && !has911Reference) {
      violations.add(
        OutputViolation(
          type: 'missing_emergency_guidance',
          severity: 'critical',
          description:
              'Mentions emergency symptom without 911/emergency care guidance',
          suggestion:
              'Add: "Call 911 or seek emergency care immediately if..."',
        ),
      );
    }

    return violations;
  }

  /// Edge case 206: Detect medication advice without professional disclaimer
  static List<OutputViolation> detectMedicationAdvice(String output) {
    final violations = <OutputViolation>[];

    final medicationKeywords = [
      'remicade',
      'humira',
      'entyvio',
      'stelara',
      'prednisone',
      'azathioprine',
      'mesalamine',
      '6-mp',
      'methotrexate',
      'budesonide',
    ];

    var hasMedication = false;
    for (final med in medicationKeywords) {
      if (output.toLowerCase().contains(med)) {
        hasMedication = true;
        break;
      }
    }

    if (hasMedication) {
      final hasDisclaimer = output.toLowerCase().contains('doctor') ||
          output.toLowerCase().contains('healthcare provider') ||
          output.toLowerCase().contains('gi specialist') ||
          output.toLowerCase().contains('prescriber');

      if (!hasDisclaimer) {
        violations.add(
          OutputViolation(
            type: 'medication_without_disclaimer',
            severity: 'high',
            description:
                'Mentions medication without healthcare provider disclaimer',
            suggestion:
                'Add: "Discuss with your doctor before making any medication changes"',
          ),
        );
      }
    }

    return violations;
  }

  // ---------------------------------------------------------------------------
  // Format Validation
  // ---------------------------------------------------------------------------

  /// Edge case 207: Validate markdown structure
  static List<OutputViolation> validateMarkdownFormat(String output) {
    final violations = <String>[];

    // Edge case 208: Check for mismatched markdown syntax
    final boldCount = '**'.allMatches(output).length;
    if (boldCount % 2 != 0) {
      violations.add('Unmatched ** bold markers');
    }

    final italicCount = '_'.allMatches(output).length;
    if (italicCount % 2 != 0) {
      violations.add('Unmatched _ italic markers');
    }

    // Edge case 209: Check for broken lists
    final lines = output.split('\n');
    var inList = false;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('• ') ||
          trimmed.startsWith('- ') ||
          RegExp(r'^\d+\.\s').hasMatch(trimmed)) {
        if (!inList) {
          inList = true;
        }
      } else if (trimmed.isEmpty) {
        inList = false;
      } else if (inList) {
        violations.add('List item without proper marker: "$trimmed"');
      }
    }

    // Edge case 210: Check for excessive line breaks (>3 consecutive)
    if (RegExp(r'\n{4,}').hasMatch(output)) {
      violations.add('Excessive blank lines (>3 consecutive)');
    }

    // Edge case 211: Check for missing section headers
    if (output.length > 500 &&
        !output.contains('##') &&
        !output.contains('**')) {
      violations.add('Long output without section headers or emphasis');
    }

    return violations
        .map(
          (v) => OutputViolation(
            type: 'format_error',
            severity: 'low',
            description: v,
          ),
        )
        .toList();
  }

  /// Edge case 212: Validate response structure
  static List<OutputViolation> validateResponseStructure({
    required String output,
    required String expectedIntent,
  }) {
    final violations = <OutputViolation>[];

    // Edge case 213: Symptom log should contain severity/duration/trigger
    if (expectedIntent == 'symptom_log') {
      final hasReviewCard = output.contains('**Symptom:**') ||
          output.contains('**Frequency:**') ||
          output.contains('**Trigger:**');

      if (!hasReviewCard) {
        violations.add(
          OutputViolation(
            type: 'missing_structure',
            severity: 'high',
            description: 'Symptom log missing review card structure',
            suggestion: 'Include: Symptom, Frequency, Trigger, Duration fields',
          ),
        );
      }
    }

    // Edge case 214: Summary should have sections
    if (expectedIntent.contains('summary')) {
      final hasSections = output.contains('##') || output.contains('**');
      if (!hasSections) {
        violations.add(
          OutputViolation(
            type: 'missing_structure',
            severity: 'medium',
            description: 'Summary missing section headers',
            suggestion: 'Add sections with ## or ** markers',
          ),
        );
      }
    }

    // Edge case 215: Risk assessment should have score/explanation
    if (expectedIntent.contains('risk')) {
      final hasScore = RegExp(
        r'\d+%|\d+/10|(?:low|medium|high) risk',
        caseSensitive: false,
      ).hasMatch(output);
      if (!hasScore) {
        violations.add(
          OutputViolation(
            type: 'missing_structure',
            severity: 'high',
            description: 'Risk assessment missing quantitative score',
            suggestion:
                'Include specific risk level (%, score, or low/medium/high)',
          ),
        );
      }
    }

    return violations;
  }

  // ---------------------------------------------------------------------------
  // Content Policy Checks
  // ---------------------------------------------------------------------------

  /// Edge case 216: Detect sensitive content
  static List<OutputViolation> detectSensitiveContent(String output) {
    final violations = <OutputViolation>[];

    // Edge case 217: Excessive medical jargon (accessibility issue)
    final jargonTerms = [
      'pathophysiology',
      'etiology',
      'remission',
      'exacerbation',
      'biomarker',
      'pharmacokinetics',
      'histopathology',
    ];

    var jargonCount = 0;
    for (final term in jargonTerms) {
      if (output.toLowerCase().contains(term)) {
        jargonCount++;
      }
    }

    if (jargonCount > 3 && output.length < 500) {
      violations.add(
        OutputViolation(
          type: 'excessive_jargon',
          severity: 'low',
          description:
              'High jargon density ($jargonCount terms in short response)',
          suggestion:
              'Simplify language or add explanations for technical terms',
        ),
      );
    }

    // Edge case 218: Fear-inducing language
    final fearWords = [
      'terrible',
      'horrible',
      'devastating',
      'catastrophic',
      'worst-case',
      'deadly',
      'fatal',
    ];

    for (final word in fearWords) {
      if (output.toLowerCase().contains(word)) {
        violations.add(
          OutputViolation(
            type: 'fear_inducing',
            severity: 'medium',
            description: 'Contains fear-inducing language: "$word"',
            suggestion: 'Use neutral, factual language',
          ),
        );
      }
    }

    // Edge case 219: Over-reassurance (minimizing valid concerns)
    final overReassurance = [
      r"\bdon't worry at all\b",
      r'\bnothing to worry about\b',
      r'\bcompletely normal\b',
      r'\bno need to be concerned\b',
    ];

    for (final pattern in overReassurance) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(output)) {
        violations.add(
          OutputViolation(
            type: 'over_reassurance',
            severity: 'medium',
            description: 'Contains over-reassuring language: "$pattern"',
            suggestion:
                'Acknowledge concern while providing balanced information',
          ),
        );
      }
    }

    return violations;
  }

  // ---------------------------------------------------------------------------
  // Response Quality Scoring
  // ---------------------------------------------------------------------------

  /// Edge case 220: Calculate overall response quality
  static ValidationResult scoreResponseQuality({
    required String output,
    required String userInput,
    required String expectedIntent,
  }) {
    var quality = 1.0;
    final warnings = <String>[];
    final allViolations = <OutputViolation>[];

    // Run all validation checks
    allViolations.addAll(detectMedicalHallucinations(output));
    allViolations.addAll(detectContradictions(output));
    allViolations.addAll(detectDiagnosticLanguage(output));
    allViolations.addAll(detectMedicationAdvice(output));
    allViolations.addAll(validateMarkdownFormat(output));
    allViolations.addAll(
      validateResponseStructure(output: output, expectedIntent: expectedIntent),
    );
    allViolations.addAll(detectSensitiveContent(output));

    // Edge case 221: Critical violations = invalid response
    final criticalCount =
        allViolations.where((v) => v.severity == 'critical').length;
    if (criticalCount > 0) {
      quality = 0.0;
    }

    // Edge case 222: High severity penalties
    final highCount = allViolations.where((v) => v.severity == 'high').length;
    quality -= highCount * 0.2;

    // Edge case 223: Medium severity penalties
    final mediumCount =
        allViolations.where((v) => v.severity == 'medium').length;
    quality -= mediumCount * 0.1;

    // Edge case 224: Low severity penalties
    final lowCount = allViolations.where((v) => v.severity == 'low').length;
    quality -= lowCount * 0.05;

    // Edge case 225: Length appropriateness
    if (output.length < 50) {
      warnings.add('Response very short (<50 chars)');
      quality -= 0.1;
    } else if (output.length > 2000) {
      warnings.add('Response very long (>2000 chars)');
      quality -= 0.05;
    }

    // Edge case 226: Relevance to user input
    final userWords = userInput.toLowerCase().split(RegExp(r'\W+'));
    final outputWords = output.toLowerCase().split(RegExp(r'\W+'));
    final overlap =
        userWords.where((w) => outputWords.contains(w) && w.length > 3).length;
    final relevance = overlap / math.max(1, userWords.length);

    if (relevance < 0.2) {
      warnings.add('Low relevance to user input');
      quality -= 0.2;
    }

    // Edge case 227: Clamp quality to [0, 1]
    quality = quality.clamp(0.0, 1.0);

    return ValidationResult(
      isValid: criticalCount == 0,
      sanitizedOutput: output,
      quality: quality,
      violations: allViolations,
      warnings: warnings,
      metadata: {
        'criticalViolations': criticalCount,
        'highViolations': highCount,
        'mediumViolations': mediumCount,
        'lowViolations': lowCount,
        'relevanceScore': relevance,
        'lengthChars': output.length,
      },
    );
  }

  /// Edge case 228: Sanitize invalid output
  static String sanitizeInvalidOutput({
    required String output,
    required List<OutputViolation> violations,
  }) {
    var sanitized = output;

    // Edge case 229: Remove diagnostic language
    for (final violation in violations) {
      if (violation.type == 'diagnostic_language') {
        sanitized = sanitized.replaceAll(
          RegExp(
            r"\byou have (?:crohn'?s|colitis|ibd)\b",
            caseSensitive: false,
          ),
          'symptoms suggest possible',
        );
        sanitized = sanitized.replaceAll(
          RegExp(r'\byour diagnosis is\b', caseSensitive: false),
          'your symptoms are consistent with',
        );
      }
    }

    // Edge case 230: Add disclaimers where missing
    for (final violation in violations) {
      if (violation.type == 'medication_without_disclaimer') {
        sanitized +=
            '\n\n**Important:** Discuss any medication changes with your healthcare provider.';
        break;
      }
    }

    // Edge case 231: Add emergency guidance where missing
    for (final violation in violations) {
      if (violation.type == 'missing_emergency_guidance') {
        sanitized +=
            '\n\n⚠️ **Seek immediate medical attention if symptoms worsen or you experience severe pain, bleeding, or high fever.**';
        break;
      }
    }

    return sanitized;
  }
}
