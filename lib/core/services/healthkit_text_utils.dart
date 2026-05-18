// Pure text utilities for HealthKit intent classification.
// No I/O, no dependencies on Flutter; safe to import from any layer.

/// Maximum chars we ever scan in a single pass. Anything beyond this is
/// truncated by the classifier before reaching these helpers.
const int kHealthKitMaxScanLength = 1024;

/// Cheap English contraction expansion. Keys MUST be lowercase. Order matters
/// — longer keys are applied first so "what's" expands before "what".
const Map<String, String> kContractions = {
  "what's": 'what is',
  "what're": 'what are',
  "how's": 'how is',
  "i'm": 'i am',
  "i've": 'i have',
  "i'll": 'i will',
  "i'd": 'i would',
  "you're": 'you are',
  "you've": 'you have',
  "don't": 'do not',
  "didn't": 'did not',
  "doesn't": 'does not',
  "haven't": 'have not',
  "hasn't": 'has not',
  "isn't": 'is not',
  "wasn't": 'was not',
  "weren't": 'were not',
  "won't": 'will not',
  "can't": 'cannot',
  "couldn't": 'could not',
  "wouldn't": 'would not',
  "shouldn't": 'should not',
  "let's": 'let us',
  "it's": 'it is',
  "that's": 'that is',
  "there's": 'there is',
};

/// Filler tokens removed before slot extraction. Removing these reduces
/// false negatives when matching long phrases.
const Set<String> kFillerTokens = {
  'um', 'uh', 'uhh', 'er', 'erm', 'like', 'just', 'maybe',
  'kinda', 'sorta', 'literally', 'basically', 'actually', 'really',
  'please', 'pls', 'plz',
  'can', 'you', 'tell', 'me', 'show', 'give',
};

/// Token patterns removed from the input. This is the conservative set —
/// punctuation is reduced but not eliminated (we keep '-' for "6-minute walk").
final RegExp _kPunctuationToStrip = RegExp(r"[.,!?;:'“”‘’\(\)\[\]\{\}]");
final RegExp _kCollapseWhitespace = RegExp(r'\s+');

/// Normalizes a user query for classification. Idempotent.
///
/// Steps:
///   1. Truncate to [kHealthKitMaxScanLength] to bound work.
///   2. Lowercase.
///   3. Expand contractions ("what's" → "what is").
///   4. Strip selected punctuation while preserving hyphens.
///   5. Collapse all whitespace runs to single spaces.
///   6. Trim leading/trailing whitespace.
///
/// Returns an empty string when the input is null/empty/whitespace.
String normalizeQuery(String input) {
  if (input.isEmpty) return '';
  var s = input.length > kHealthKitMaxScanLength
      ? input.substring(0, kHealthKitMaxScanLength)
      : input;
  s = s.toLowerCase();
  for (final entry in kContractions.entries) {
    if (s.contains(entry.key)) s = s.replaceAll(entry.key, entry.value);
  }
  s = s.replaceAll(_kPunctuationToStrip, ' ');
  s = s.replaceAll(_kCollapseWhitespace, ' ').trim();
  return s;
}

/// Tokenizes the normalized query into whitespace-separated tokens.
/// Filler tokens are NOT removed here — call [tokenizeWithoutFillers] for that.
List<String> tokenize(String normalized) {
  if (normalized.isEmpty) return const [];
  return normalized.split(' ').where((t) => t.isNotEmpty).toList(growable: false);
}

/// Tokenizes and removes filler words. Empty list when nothing remains.
List<String> tokenizeWithoutFillers(String normalized) {
  return tokenize(normalized)
      .where((t) => !kFillerTokens.contains(t))
      .toList(growable: false);
}

/// Returns the Levenshtein edit distance between [a] and [b].
///
/// Implementation uses two rolling rows of size O(min(|a|, |b|)) to avoid
/// allocating a full matrix. Linear in memory, quadratic in time.
///
/// Returns `min(a.length, b.length).clamp(0, threshold + 1)` early when the
/// running minimum exceeds [threshold] — callers can skip non-matches fast.
int levenshtein(String a, String b, {int threshold = 999}) {
  if (identical(a, b) || a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  if ((a.length - b.length).abs() > threshold) return threshold + 1;

  // Ensure b is the shorter string for memory efficiency.
  final String s1;
  final String s2;
  if (a.length < b.length) {
    s1 = b;
    s2 = a;
  } else {
    s1 = a;
    s2 = b;
  }

  final n = s2.length;
  var prev = List<int>.generate(n + 1, (i) => i, growable: false);
  var curr = List<int>.filled(n + 1, 0);

  for (var i = 1; i <= s1.length; i++) {
    curr[0] = i;
    var rowMin = curr[0];
    final s1i = s1.codeUnitAt(i - 1);
    for (var j = 1; j <= n; j++) {
      final cost = (s1i == s2.codeUnitAt(j - 1)) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      var v = del;
      if (ins < v) v = ins;
      if (sub < v) v = sub;
      curr[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > threshold) return threshold + 1;
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

/// Generates a short opaque trace id ('hk_' + 6 lowercase alphanumerics).
/// Deterministic given [seed]; if [seed] is null uses a microsecond clock.
///
/// Never include PHI or user input in the seed.
String generateTraceId([Object? seed]) {
  final basis = seed?.toString().hashCode ??
      DateTime.now().microsecondsSinceEpoch;
  final h = (basis ^ 0x9E3779B97F4A7C15).abs();
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  final buf = StringBuffer('hk_');
  var v = h;
  for (var i = 0; i < 6; i++) {
    buf.writeCharCode(alphabet.codeUnitAt(v % alphabet.length));
    v ~/= alphabet.length;
    if (v == 0) v = h ^ (i * 0x100000001B3);
  }
  return buf.toString();
}

/// Computes confidence for a fuzzy match given the input phrase length and
/// the achieved edit distance. Returns a value in [0.0, 1.0].
///
///   editDistance=0 → 1.0
///   editDistance=phraseLength → 0.0
///   intermediate → linear interpolation
double fuzzyConfidence(int phraseLength, int editDistance) {
  if (phraseLength <= 0) return 0.0;
  if (editDistance <= 0) return 1.0;
  if (editDistance >= phraseLength) return 0.0;
  final raw = 1.0 - (editDistance / phraseLength);
  return raw.clamp(0.0, 1.0);
}

/// Geometric mean of slot confidences. Returns 0.0 when [values] is empty
/// or any value is 0.0 (a single missing slot collapses overall confidence).
double aggregateConfidence(Iterable<double> values) {
  final list = values.toList(growable: false);
  if (list.isEmpty) return 0.0;
  var product = 1.0;
  for (final v in list) {
    if (v <= 0.0) return 0.0;
    product *= v;
  }
  // Nth root via pow trick: product^(1/n) = exp(ln(product) / n)
  // For small n we can use repeated sqrt for stability, but pow is fine here.
  if (list.length == 1) return product.clamp(0.0, 1.0);
  return _nthRoot(product, list.length).clamp(0.0, 1.0);
}

double _nthRoot(double value, int n) {
  if (value <= 0.0 || n <= 0) return 0.0;
  // value^(1/n) computed without dart:math import — Newton's method.
  var x = value;
  for (var i = 0; i < 32; i++) {
    final f = _pow(x, n) - value;
    final fp = n * _pow(x, n - 1);
    if (fp == 0.0) break;
    final nextX = x - f / fp;
    if ((nextX - x).abs() < 1e-12) {
      x = nextX;
      break;
    }
    x = nextX;
  }
  return x;
}

double _pow(double base, int exp) {
  if (exp == 0) return 1.0;
  var result = 1.0;
  var b = base;
  var e = exp;
  while (e > 0) {
    if ((e & 1) == 1) result *= b;
    b *= b;
    e >>= 1;
  }
  return result;
}
