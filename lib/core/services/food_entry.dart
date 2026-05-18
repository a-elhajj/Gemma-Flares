// =============================================================================
// FoodEntry — data model for food / dietary logging.
// =============================================================================
// GutGuard users can log meals, foods, and dietary events.  These entries are
// indexed into the RAG corpus so Gemma can reference recent dietary patterns
// when providing personalized GI context.
//
// Storage:
//   • RAG corpus: plaintext chunk in <AppSupport>/GutGuard/LiteRtLm/corpus/
//   • Vector index: 'food' collection in the active VectorStore
//   • SQLite: food_entries table
//
// All fields are nullable where the user may not know or care about the value.
// =============================================================================

class FoodEntry {
  const FoodEntry({
    this.id,
    required this.loggedAt,
    required this.foodName,
    this.description,
    this.mealType,
    this.calories,
    this.portionGrams,
    this.portionUnit,
    this.isGlutenFree,
    this.isLactoseFree,
    this.isDairyFree,
    this.isHighFiber,
    this.isHighFat,
    this.isSpicy,
    this.fiberGrams,
    this.proteinGrams,
    this.fatGrams,
    this.carbGrams,
    this.sugarGrams,
    this.sodiumMg,
    this.allergens = const [],
    this.notes,
    this.triggerSuspected = false,
    this.source = 'manual',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? loggedAt;

  final int? id;
  final DateTime loggedAt;

  /// Display name of the food (e.g. 'Greek yogurt', 'Chicken and rice').
  final String foodName;

  /// Optional longer description (e.g. 'Low-fat, plain, with blueberries').
  final String? description;

  /// Meal context: 'breakfast' | 'lunch' | 'dinner' | 'snack' | 'other'.
  final String? mealType;

  // ── Macros ────────────────────────────────────────────────────────────────

  /// Energy in kilocalories.
  final double? calories;

  /// Portion size in grams (null if unknown).
  final double? portionGrams;

  /// Portion unit as logged by user ('g' | 'oz' | 'cup' | 'tbsp' | 'piece' | 'slice').
  final String? portionUnit;

  final double? fiberGrams;
  final double? proteinGrams;
  final double? fatGrams;
  final double? carbGrams;
  final double? sugarGrams;
  final double? sodiumMg;

  // ── Dietary flags ─────────────────────────────────────────────────────────

  final bool? isGlutenFree;
  final bool? isLactoseFree;
  final bool? isDairyFree;
  final bool? isHighFiber;
  final bool? isHighFat;
  final bool? isSpicy;

  /// Known allergens present (e.g. ['gluten', 'dairy', 'nuts', 'soy']).
  final List<String> allergens;

  /// User notes about this food entry.
  final String? notes;

  /// User suspects this food triggered a GI symptom.
  final bool triggerSuspected;

  /// How the entry was created: 'manual' | 'healthkit' | 'gemma_extracted' | 'barcode'.
  final String source;

  final DateTime createdAt;

  // ── Serialization ─────────────────────────────────────────────────────────

  Map<String, Object?> toJson() => {
        'id': id,
        'logged_at': loggedAt.toUtc().toIso8601String(),
        'food_name': foodName,
        'description': description,
        'meal_type': mealType,
        'calories': calories,
        'portion_grams': portionGrams,
        'portion_unit': portionUnit,
        'is_gluten_free': isGlutenFree,
        'is_lactose_free': isLactoseFree,
        'is_dairy_free': isDairyFree,
        'is_high_fiber': isHighFiber,
        'is_high_fat': isHighFat,
        'is_spicy': isSpicy,
        'fiber_grams': fiberGrams,
        'protein_grams': proteinGrams,
        'fat_grams': fatGrams,
        'carb_grams': carbGrams,
        'sugar_grams': sugarGrams,
        'sodium_mg': sodiumMg,
        'allergens': allergens,
        'notes': notes,
        'trigger_suspected': triggerSuspected,
        'source': source,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory FoodEntry.fromJson(Map<String, Object?> json) => FoodEntry(
        id: json['id'] as int?,
        loggedAt: DateTime.parse(json['logged_at'] as String),
        foodName: json['food_name'] as String,
        description: json['description'] as String?,
        mealType: json['meal_type'] as String?,
        calories: (json['calories'] as num?)?.toDouble(),
        portionGrams: (json['portion_grams'] as num?)?.toDouble(),
        portionUnit: json['portion_unit'] as String?,
        isGlutenFree: json['is_gluten_free'] as bool?,
        isLactoseFree: json['is_lactose_free'] as bool?,
        isDairyFree: json['is_dairy_free'] as bool?,
        isHighFiber: json['is_high_fiber'] as bool?,
        isHighFat: json['is_high_fat'] as bool?,
        isSpicy: json['is_spicy'] as bool?,
        fiberGrams: (json['fiber_grams'] as num?)?.toDouble(),
        proteinGrams: (json['protein_grams'] as num?)?.toDouble(),
        fatGrams: (json['fat_grams'] as num?)?.toDouble(),
        carbGrams: (json['carb_grams'] as num?)?.toDouble(),
        sugarGrams: (json['sugar_grams'] as num?)?.toDouble(),
        sodiumMg: (json['sodium_mg'] as num?)?.toDouble(),
        allergens: (json['allergens'] as List?)?.cast<String>() ?? const [],
        notes: json['notes'] as String?,
        triggerSuspected: json['trigger_suspected'] as bool? ?? false,
        source: json['source'] as String? ?? 'manual',
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  FoodEntry copyWith({
    int? id,
    DateTime? loggedAt,
    String? foodName,
    String? description,
    String? mealType,
    double? calories,
    double? portionGrams,
    String? portionUnit,
    bool? isGlutenFree,
    bool? isLactoseFree,
    bool? isDairyFree,
    bool? isHighFiber,
    bool? isHighFat,
    bool? isSpicy,
    double? fiberGrams,
    double? proteinGrams,
    double? fatGrams,
    double? carbGrams,
    double? sugarGrams,
    double? sodiumMg,
    List<String>? allergens,
    String? notes,
    bool? triggerSuspected,
    String? source,
    DateTime? createdAt,
  }) =>
      FoodEntry(
        id: id ?? this.id,
        loggedAt: loggedAt ?? this.loggedAt,
        foodName: foodName ?? this.foodName,
        description: description ?? this.description,
        mealType: mealType ?? this.mealType,
        calories: calories ?? this.calories,
        portionGrams: portionGrams ?? this.portionGrams,
        portionUnit: portionUnit ?? this.portionUnit,
        isGlutenFree: isGlutenFree ?? this.isGlutenFree,
        isLactoseFree: isLactoseFree ?? this.isLactoseFree,
        isDairyFree: isDairyFree ?? this.isDairyFree,
        isHighFiber: isHighFiber ?? this.isHighFiber,
        isHighFat: isHighFat ?? this.isHighFat,
        isSpicy: isSpicy ?? this.isSpicy,
        fiberGrams: fiberGrams ?? this.fiberGrams,
        proteinGrams: proteinGrams ?? this.proteinGrams,
        fatGrams: fatGrams ?? this.fatGrams,
        carbGrams: carbGrams ?? this.carbGrams,
        sugarGrams: sugarGrams ?? this.sugarGrams,
        sodiumMg: sodiumMg ?? this.sodiumMg,
        allergens: allergens ?? this.allergens,
        notes: notes ?? this.notes,
        triggerSuspected: triggerSuspected ?? this.triggerSuspected,
        source: source ?? this.source,
        createdAt: createdAt ?? this.createdAt,
      );
}

// ---------------------------------------------------------------------------
// Allergen constants
// ---------------------------------------------------------------------------

abstract class Allergen {
  static const gluten = 'gluten';
  static const dairy = 'dairy';
  static const nuts = 'nuts';
  static const soy = 'soy';
  static const eggs = 'eggs';
  static const fish = 'fish';
  static const shellfish = 'shellfish';
  static const wheat = 'wheat';
  static const sesame = 'sesame';
}

// ---------------------------------------------------------------------------
// Meal type constants
// ---------------------------------------------------------------------------

abstract class MealType {
  static const breakfast = 'breakfast';
  static const lunch = 'lunch';
  static const dinner = 'dinner';
  static const snack = 'snack';
  static const other = 'other';

  static const all = [breakfast, lunch, dinner, snack, other];
}
