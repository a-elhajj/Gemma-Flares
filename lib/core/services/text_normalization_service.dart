/// Shared text normalization for intent and preset matching.
///
/// Deterministic normalization keeps routing logic stable under common
/// misspellings, shorthand, and voice-transcription noise.
class TextNormalizationService {
  const TextNormalizationService._();

  static const Map<String, String> _tokenReplacements = {
    // =========================================================================
    // Common typos and shortcuts (original set)
    // =========================================================================
    'whats': 'what',
    'whatss': 'what',
    'wht': 'what',
    'wath': 'what',
    'u': 'you',
    'ur': 'your',
    'pls': 'please',
    'plz': 'please',
    'thx': 'thanks',
    'thanx': 'thanks',
    'symtom': 'symptom',
    'syptom': 'symptom',
    'sympom': 'symptom',
    'symotm': 'symptom',
    'symotoms': 'symptoms',
    'symtoms': 'symptoms',
    'diarreha': 'diarrhea',
    'diahrrea': 'diarrhea',
    'diarhea': 'diarrhea',
    'urgncy': 'urgency',
    'urgancy': 'urgency',
    'tenesmusss': 'tenesmus',
    'constiption': 'constipation',
    'constaption': 'constipation',
    'constipatedd': 'constipated',
    'bloateed': 'bloated',
    'bloatng': 'bloating',
    'mucuos': 'mucus',
    'mucouss': 'mucus',
    'pusy': 'pus',
    'incontinance': 'incontinence',
    'incontinenece': 'incontinence',
    'fistulla': 'fistula',
    'fisssure': 'fissure',
    'naseua': 'nausea',
    'nausia': 'nausea',
    'vomitting': 'vomiting',
    'vommiting': 'vomiting',
    'fatiuge': 'fatigue',
    'fatgue': 'fatigue',
    'migrane': 'migraine',
    'migraines': 'migraine',
    'chek': 'check',
    'chekck': 'check',
    'starrt': 'start',
    'scna': 'scan',
    'fotho': 'photo',
    'reslts': 'results',
    'resutls': 'results',
    'xplain': 'explain',
    'expalin': 'explain',
    'summry': 'summary',
    'smmary': 'summary',
    'memry': 'memory',
    'leder': 'ledger',
    'flaree': 'flare',
    'colitiss': 'colitis',
    'xrohns': 'crohns',
    'crohns': 'crohn',
    'krons': 'crohn',
    'crons': 'crohn',
    'kronz': 'crohn',
    'crohnes': 'crohn',
    'colitas': 'colitis',
    'collitis': 'colitis',
    'colotis': 'colitis',
    'kolitis': 'colitis',
    'colitcs': 'colitis',
    'proctitus': 'proctitis',
    'proctitas': 'proctitis',
    'ilitis': 'ileitis',
    'ileites': 'ileitis',
    'fistual': 'fistula',
    'fistla': 'fistula',
    'abcess': 'abscess',
    'absess': 'abscess',
    'strictuer': 'stricture',
    'strikture': 'stricture',
    'diarrea': 'diarrhea',
    'diarrheia': 'diarrhea',
    'diahrea': 'diarrhea',
    'constipaiton': 'constipation',
    'constipaton': 'constipation',
    'fatuge': 'fatigue',
    'nausua': 'nausea',
    'nauseia': 'nausea',
    'bleading': 'bleeding',
    'bleeing': 'bleeding',
    'bloathing': 'bloating',
    'colit': 'colitis',
    'ibdss': 'ibd',
    '2day': 'today',

    // =========================================================================
    // EXPANSION: 100+ Additional Edge Cases for Production Hardening
    // =========================================================================

    // Voice transcription errors (Siri/Google Assistant)
    'dye area': 'diarrhea',
    'die area': 'diarrhea',
    'diary ah': 'diarrhea',
    'dire rhea': 'diarrhea',
    'constapation': 'constipation',
    'constipated': 'constipated',
    'blooding': 'bleeding',
    'bleding': 'bleeding',
    'beleeding': 'bleeding',
    'crampping': 'cramping',
    'crampingg': 'cramping',
    'abdomanal': 'abdominal',
    'abdomenal': 'abdominal',
    'stomache': 'stomach',
    'stomachh': 'stomach',
    'stomak': 'stomach',

    // Medical terminology typos
    'crps': 'crp', // C-reactive protein
    'esrr': 'esr',
    'calproptectin': 'calprotectin',
    'calprotectinn': 'calprotectin',
    'feccal': 'fecal',
    'feecal': 'fecal',
    'hemmoglobin': 'hemoglobin',
    'hemoglob': 'hemoglobin',
    'ferritinn': 'ferritin',
    'ferratin': 'ferritin',
    'albuminn': 'albumin',
    'albumen': 'albumin',
    'colonscopy': 'colonoscopy',
    'colonsocopy': 'colonoscopy',
    'endoscopy': 'endoscopy',
    'endosocpy': 'endoscopy',
    'biopsie': 'biopsy',
    'byopsy': 'biopsy',

    // Medication name typos
    'remicaide': 'remicade',
    'humira': 'humira',
    'humiraa': 'humira',
    'prednisone': 'prednisone',
    'prednison': 'prednisone',
    'predisone': 'prednisone',
    'azathiprine': 'azathioprine',
    'azathioprin': 'azathioprine',
    'mesalamine': 'mesalamine',
    'mesalamin': 'mesalamine',
    'mesalmine': 'mesalamine',
    'budesonide': 'budesonide',
    'budesinide': 'budesonide',
    'meds': 'medications',
    'medz': 'medications',
    'medciation': 'medication',
    'medcation': 'medication',
    'medicatoin': 'medication',
    'medicaton': 'medication',
    'medecine': 'medicine',
    'medcine': 'medicine',
    'vitamins': 'vitamins',
    'vitamens': 'vitamins',
    'vitimin': 'vitamin',
    'vitimins': 'vitamins',
    'suplement': 'supplement',
    'supliment': 'supplement',
    'suppliment': 'supplement',
    'biologics': 'biologic',
    'bioligic': 'biologic',
    'bioligics': 'biologic',
    'injetion': 'injection',
    'injecton': 'injection',
    'infussion': 'infusion',

    // Symptom descriptions - common misspellings
    'abdomnal': 'abdominal',
    'stomch': 'stomach',
    'bowel': 'bowel',
    'bowells': 'bowel',
    'movment': 'movement',
    'movemnt': 'movement',
    'painfull': 'painful',
    'painfuil': 'painful',
    'seveer': 'severe',
    'severre': 'severe',
    'urgnt': 'urgent',
    'urgentt': 'urgent',
    'frecuency': 'frequency',
    'frequancy': 'frequency',
    'consitency': 'consistency',
    'consistancy': 'consistency',

    // Time-related terms
    'yesturday': 'yesterday',
    'yeseterday': 'yesterday',
    'tomorow': 'tomorrow',
    'tommorow': 'tomorrow',
    'tonite': 'tonight',
    'tongiht': 'tonight',
    'weakly': 'weekly',
    'weeklly': 'weekly',
    'monthy': 'monthly',
    'montly': 'monthly',

    // Command shortcuts and slang
    'wat': 'what',
    'wut': 'what',
    'whut': 'what',
    'wen': 'when',
    'hw': 'how',
    'hav': 'have',
    'wuz': 'was',
    'wer': 'were',
    'shud': 'should',
    'cud': 'could',
    'wud': 'would',
    'cuz': 'because',
    'bcuz': 'because',
    'bcz': 'because',
    'thru': 'through',
    'tho': 'though',
    'thot': 'thought',
    'thght': 'thought',
    'bout': 'about',
    'abt': 'about',
    'frum': 'from',
    'frm': 'from',

    // Numbers and measurements (text)
    'wun': 'one',
    'too': 'two', // Risky - also means "also", need context
    'tree': 'three',
    'fer': 'for', // Also "four" in some contexts
    'fiv': 'five',
    'nite': 'night',

    // IBD-specific colloquialisms
    'poop': 'stool',
    'pooping': 'bowel movement',
    'pooped': 'stool',
    'bm': 'bowel movement',
    'bms': 'bowel movements',
    'tummy': 'stomach',
    'belly': 'abdomen',
    'gut': 'intestine',
    'guts': 'intestines',

    // Frequency adverbs
    'alot': 'a lot',
    'alott': 'a lot',
    'allot': 'a lot',
    'rlly': 'really',
    'realy': 'really',
    'relly': 'really',
    'verry': 'very',
    'veryyy': 'very',
    'extreamly': 'extremely',
    'extremly': 'extremely',
    'kinda': 'kind of',
    'sorta': 'sort of',
    'lotsa': 'lots of',
    'lotta': 'lot of',

    // Negations and corrections
    'didnt': 'did not',
    'dont': 'do not',
    'doesnt': 'does not',
    'wasnt': 'was not',
    'werent': 'were not',
    'isnt': 'is not',
    'arent': 'are not',
    'hasnt': 'has not',
    'havent': 'have not',
    'wont': 'will not',
    'wouldnt': 'would not',
    'couldnt': 'could not',
    'shouldnt': 'should not',
    'cant': 'can not',

    // Lab/medical procedure typos
    'blod': 'blood',
    'bloud': 'blood',
    'bloodd': 'blood',
    'workk': 'work',
    'wrok': 'work',
    'testt': 'test',
    'tets': 'test',
    'scann': 'scan',
    'scaning': 'scanning',
    'imageing': 'imaging',
    'imging': 'imaging',
    'xray': 'x-ray',
    'x ray': 'x-ray',
    'mrii': 'mri',
    'ct': 'ct',
    'catscan': 'ct scan',

    // Risk and severity terms
    'risc': 'risk',
    'riskk': 'risk',
    'dangr': 'danger',
    'dangrous': 'dangerous',
    'emergancy': 'emergency',
    'emergenc': 'emergency',
    'urget': 'urgent',
    'sever': 'severe',
    'moderarte': 'moderate',
    'modrate': 'moderate',
    'mildd': 'mild',

    // Doctor/medical professional terms
    'doctr': 'doctor',
    'docter': 'doctor',
    'physicain': 'physician',
    'phisician': 'physician',
    'gastro': 'gastroenterologist',
    'gastrontrologist': 'gastroenterologist',
    'specialist': 'specialist',
    'specailist': 'specialist',
    'appoitment': 'appointment',
    'apointment': 'appointment',
    'appointmnt': 'appointment',

    // Food/diet terms
    'deit': 'diet',
    'diett': 'diet',
    'foood': 'food',
    'ate': 'ate',
    'eatting': 'eating',
    'eatn': 'eating',
    'drank': 'drank',
    'drinking': 'drinking',
    'drinkin': 'drinking',
    'glutan': 'gluten',
    'gluton': 'gluten',
    'diry': 'dairy',
    'darey': 'dairy',
    'lactose': 'lactose',
    'lactoes': 'lactose',
    'triggr': 'trigger',
    'triiger': 'trigger',

    // Emotional state terms
    'anxius': 'anxious',
    'anxous': 'anxious',
    'worreid': 'worried',
    'worried': 'worried',
    'stressd': 'stressed',
    'stresssed': 'stressed',
    'scred': 'scared',
    'scared': 'scared',
    'afraide': 'afraid',
    'afrad': 'afraid',
    'terified': 'terrified',
    'terrifyed': 'terrified',
    'overwhelmd': 'overwhelmed',
    'depresed': 'depressed',
    'depressd': 'depressed',

    // App command typos
    'logg': 'log',
    'loging': 'logging',
    // "cancel" misspellings including diacritic-stripped input like "cancé" → "canc"
    'canc': 'cancel',
    'cance': 'cancel',
    'recoord': 'record',
    'recordd': 'record',
    'savve': 'save',
    'savee': 'save',
    'shwo': 'show',
    'shoow': 'show',
    'disply': 'display',
    'dispaly': 'display',
    'creat': 'create',
    'creatte': 'create',
    'delet': 'delete',
    'deletee': 'delete',
    'remov': 'remove',
    'removee': 'remove',
    'exprt': 'export',
    'exportt': 'export',
  };

  static String normalizeForIntent(String value) {
    var normalized = value.toLowerCase();
    normalized = normalized
        .replaceAll("what's", 'what is')
        .replaceAll('whats', 'what is')
        .replaceAll("i'm", 'i am')
        .replaceAll("i’ve", 'i have')
        .replaceAll("ive", 'i have')
        .replaceAll("can't", 'cant')
        .replaceAll("cannot", 'cant')
        .replaceAll("won't", 'wont')
        .replaceAll("don't", 'dont')
        .replaceAll('check-in', 'check in')
        .replaceAll('flare-risk', 'flare risk')
        .replaceAll('lab-photo', 'lab photo')
        .replaceAll('head ache', 'headache')
        .replaceAll('back ache', 'backache');

    normalized = normalized
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) return normalized;

    final replaced = normalized
        .split(' ')
        .map((token) => _tokenReplacements[token] ?? token)
        .join(' ');
    return replaced.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
