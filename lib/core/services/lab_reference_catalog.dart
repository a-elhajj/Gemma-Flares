class LabReferenceDefinition {
  const LabReferenceDefinition({
    required this.primaryKey,
    required this.aliases,
    required this.whatItMeasures,
    required this.ibdUse,
    required this.caveat,
  });

  final String primaryKey;
  final List<String> aliases;
  final String whatItMeasures;
  final String ibdUse;
  final String caveat;
}

const kLabReferenceCatalog = <LabReferenceDefinition>[
  LabReferenceDefinition(
    primaryKey: 'fecal_calprotectin',
    aliases: ['fc', 'calprotectin', 'fecal_calprotectin'],
    whatItMeasures: 'Gut-specific inflammatory protein in stool.',
    ibdUse: 'Tracks intestinal inflammation and relapse risk.',
    caveat: 'Can rise from infection or NSAID exposure as well.',
  ),
  LabReferenceDefinition(
    primaryKey: 'crp',
    aliases: ['crp', 'c reactive protein'],
    whatItMeasures: 'Acute phase blood inflammation marker.',
    ibdUse: 'Monitors systemic inflammatory activity over time.',
    caveat: 'May stay low despite active disease in some patients.',
  ),
  LabReferenceDefinition(
    primaryKey: 'esr',
    aliases: ['esr', 'sed rate', 'erythrocyte sedimentation rate'],
    whatItMeasures: 'Rate of red-cell settling in plasma.',
    ibdUse: 'Slow-moving inflammation trend marker.',
    caveat: 'Changes slower than CRP and can be affected by anemia.',
  ),
  LabReferenceDefinition(
    primaryKey: 'hemoglobin',
    aliases: ['hemoglobin', 'hgb'],
    whatItMeasures: 'Oxygen-carrying protein concentration.',
    ibdUse: 'Screens for chronic blood loss or iron deficiency impact.',
    caveat: 'Hydration and bleeding timing can affect interpretation.',
  ),
  LabReferenceDefinition(
    primaryKey: 'wbc',
    aliases: ['wbc', 'white blood cell', 'white blood cells'],
    whatItMeasures: 'Immune cell count in blood.',
    ibdUse: 'Flags infection, inflammation, or steroid effect context.',
    caveat: 'Medication effects can shift values independent of disease.',
  ),
  LabReferenceDefinition(
    primaryKey: 'platelet',
    aliases: ['platelet', 'platelets', 'plt'],
    whatItMeasures: 'Platelet count in blood.',
    ibdUse: 'Can trend upward during active inflammation.',
    caveat: 'Iron deficiency can also elevate platelets.',
  ),
  LabReferenceDefinition(
    primaryKey: 'albumin',
    aliases: ['albumin'],
    whatItMeasures: 'Major circulating protein level.',
    ibdUse: 'Tracks nutrition/protein loss in severe disease.',
    caveat: 'Liver function and hydration also influence level.',
  ),
  LabReferenceDefinition(
    primaryKey: 'ferritin',
    aliases: ['ferritin'],
    whatItMeasures: 'Iron storage protein level.',
    ibdUse: 'Assesses iron deficiency in chronic GI symptoms.',
    caveat: 'Inflammation can artificially raise ferritin.',
  ),
  LabReferenceDefinition(
    primaryKey: 'vitamin_b12',
    aliases: ['b12', 'vitamin b12', 'vitamin_b12'],
    whatItMeasures: 'Vitamin B12 blood concentration.',
    ibdUse: 'Detects malabsorption risk, especially ileal disease.',
    caveat: 'Supplements and injections can temporarily inflate values.',
  ),
  LabReferenceDefinition(
    primaryKey: 'vitamin_d',
    aliases: ['vitamin d', '25 oh vitamin d', 'vitamin_d'],
    whatItMeasures: 'Vitamin D status marker.',
    ibdUse: 'Supports bone and immune health monitoring.',
    caveat: 'Seasonal sunlight exposure affects baseline.',
  ),
  LabReferenceDefinition(
    primaryKey: 'ast',
    aliases: ['ast', 'sgot'],
    whatItMeasures: 'Liver enzyme from hepatocyte turnover.',
    ibdUse: 'Monitors liver safety with some therapies.',
    caveat: 'Muscle injury can also increase AST.',
  ),
  LabReferenceDefinition(
    primaryKey: 'alt',
    aliases: ['alt', 'sgpt'],
    whatItMeasures: 'Liver enzyme linked to hepatocellular stress.',
    ibdUse: 'Checks medication and hepatobiliary safety.',
    caveat: 'Transient elevations can occur after acute illness.',
  ),
  LabReferenceDefinition(
    primaryKey: 'alp',
    aliases: ['alp', 'alkaline phosphatase'],
    whatItMeasures: 'Enzyme from liver/bone pathways.',
    ibdUse: 'Context for cholestatic or bone-related changes.',
    caveat: 'Bone growth and pregnancy can elevate ALP.',
  ),
  LabReferenceDefinition(
    primaryKey: 'bilirubin',
    aliases: ['bilirubin', 'total bilirubin'],
    whatItMeasures: 'Hemoglobin breakdown product.',
    ibdUse: 'General liver function context.',
    caveat: 'Gilbert syndrome can raise bilirubin without injury.',
  ),
  LabReferenceDefinition(
    primaryKey: 'creatinine',
    aliases: ['creatinine'],
    whatItMeasures: 'Kidney filtration marker.',
    ibdUse: 'Medication and dehydration safety monitoring.',
    caveat: 'Muscle mass influences baseline creatinine.',
  ),
  LabReferenceDefinition(
    primaryKey: 'egfr',
    aliases: ['egfr', 'estimated gfr'],
    whatItMeasures: 'Estimated kidney filtration rate.',
    ibdUse: 'Renal safety trend with chronic care.',
    caveat: 'Estimate quality depends on age/sex assumptions.',
  ),
  LabReferenceDefinition(
    primaryKey: 'sodium',
    aliases: ['sodium', 'na'],
    whatItMeasures: 'Serum sodium concentration.',
    ibdUse: 'Hydration and electrolyte status during flares.',
    caveat: 'Fluid shifts can change sodium rapidly.',
  ),
  LabReferenceDefinition(
    primaryKey: 'potassium',
    aliases: ['potassium', 'k'],
    whatItMeasures: 'Serum potassium concentration.',
    ibdUse: 'Electrolyte safety with diarrhea/vomiting.',
    caveat: 'Sample handling can falsely elevate potassium.',
  ),
  LabReferenceDefinition(
    primaryKey: 'chloride',
    aliases: ['chloride', 'cl'],
    whatItMeasures: 'Serum chloride concentration.',
    ibdUse: 'Electrolyte/acid-base balance context.',
    caveat: 'Interpret with bicarbonate and sodium together.',
  ),
  LabReferenceDefinition(
    primaryKey: 'co2',
    aliases: ['co2', 'bicarbonate', 'hco3'],
    whatItMeasures: 'Serum bicarbonate/total CO2 marker.',
    ibdUse: 'Acid-base status during GI losses.',
    caveat: 'Respiratory disorders can alter bicarbonate too.',
  ),
  LabReferenceDefinition(
    primaryKey: 'tsh',
    aliases: ['tsh', 'thyroid stimulating hormone'],
    whatItMeasures: 'Thyroid regulatory hormone level.',
    ibdUse: 'Fatigue/weight symptom differential context.',
    caveat: 'Interpret with FT4/FT3 for full thyroid picture.',
  ),
  LabReferenceDefinition(
    primaryKey: 'rbc',
    aliases: ['rbc', 'red blood cells'],
    whatItMeasures: 'Red blood cell count.',
    ibdUse: 'Anemia trend context in chronic disease.',
    caveat: 'Hydration can affect concentration measures.',
  ),
  LabReferenceDefinition(
    primaryKey: 'mcv',
    aliases: ['mcv'],
    whatItMeasures: 'Average red blood cell size.',
    ibdUse: 'Helps classify anemia subtype.',
    caveat: 'Mixed deficiencies can mask classic patterns.',
  ),
  LabReferenceDefinition(
    primaryKey: 'mch',
    aliases: ['mch'],
    whatItMeasures: 'Average hemoglobin mass per red cell.',
    ibdUse: 'Supports anemia subtype interpretation.',
    caveat: 'Use with MCV and ferritin for better signal.',
  ),
  LabReferenceDefinition(
    primaryKey: 'rdw',
    aliases: ['rdw'],
    whatItMeasures: 'Red-cell size variability.',
    ibdUse: 'Can indicate evolving nutrient deficiencies.',
    caveat: 'Not specific on its own.',
  ),
];

LabReferenceDefinition? findLabReference(String labTypeOrName) {
  final normalized = labTypeOrName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return null;
  for (final row in kLabReferenceCatalog) {
    if (row.primaryKey == normalized) return row;
    if (row.aliases.any((alias) => normalized.contains(alias))) return row;
  }
  return null;
}
