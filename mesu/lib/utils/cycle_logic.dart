import 'dart:math';

/// CycleLogic - God-Tier Prediction Algorithm
/// 
/// Features:
/// 1. Weighted Moving Average (EMA) - Recent cycles matter more
/// 2. Standard Deviation - Prediction window for irregular cycles
/// 3. Stress Factor - Adjusts for cortisol-related delays
/// 4. Dynamic Luteal Phase - Personal luteal length (not assumed 14)
/// 5. Symptom Correlation - "Headache = Period in 2 days" logic
/// 6. Ghost Period Detection - Catches missed logging
class CycleLogic {
  
  static const int defaultCycleLength = 28;
  static const int defaultLutealLength = 14;
  
  /// Phase definitions with boyfriend-friendly tips
  static const Map<String, Map<String, dynamic>> phases = {
    'menstruation': {
      'name': 'Menstruation',
      'emoji': '🩸',
      'color': 0xFFE53935,
      'description': 'The "Winter" phase - Low energy time',
      'tip': 'She\'s in the "Winter" phase. Low energy. Bring comfort food, don\'t ask for big favors.',
      'tips': [
        'Bring her favorite comfort food',
        'Don\'t plan anything too active',
        'Extra cuddles are appreciated',
        'Be patient with low energy',
      ],
    },
    'follicular': {
      'name': 'Follicular',
      'emoji': '🌱',
      'color': 0xFF43A047,
      'description': 'Energy is rising - Great time for dates!',
      'tip': 'Energy is rising! She\'s likely feeling social and happy. Great time for a date night.',
      'tips': [
        'Plan that date night!',
        'She\'s feeling social and happy',
        'Great time for new activities',
        'Energy is coming back strong',
      ],
    },
    'ovulation': {
      'name': 'Ovulation Window',
      'emoji': '✨',
      'color': 0xFFFFB300,
      'description': 'Peak energy and confidence',
      'tip': 'Peak energy and confidence. She might be feeling extra affectionate.',
      'tips': [
        'She\'s at peak confidence',
        'Feeling extra affectionate',
        'Best communication days',
        'High energy for anything',
      ],
    },
    'luteal': {
      'name': 'Luteal (PMS Zone)',
      'emoji': '🍂',
      'color': 0xFF8E24AA,
      'description': 'The PMS Zone - Be extra patient',
      'tip': 'The "PMS" Zone. Energy is dropping. Be patient if she gets irritated easily.',
      'tips': [
        'Be extra patient right now',
        'Don\'t take irritation personally',
        'Comfort snacks are your friend',
        'Keep plans low-key',
      ],
    },
    'late': {
      'name': 'Late',
      'emoji': '⏳',
      'color': 0xFF757575,
      'description': 'Cycle is taking longer than usual',
      'tip': 'Cycle is taking longer than usual. Don\'t panic, bodies aren\'t robots.',
      'tips': [
        'Bodies aren\'t robots',
        'Stress can delay cycles',
        'Completely normal variation',
        'Just wait it out',
      ],
    },
  };

  // ============================================================
  // 1. WEIGHTED MOVING AVERAGE (EMA)
  // ============================================================
  
  /// Calculate weighted average - recent cycles matter MORE
  static double calculateWeightedAverage(List<int> cycleLengths) {
    if (cycleLengths.isEmpty) return defaultCycleLength.toDouble();
    if (cycleLengths.length == 1) return cycleLengths[0].toDouble();
    if (cycleLengths.length == 2) {
      return (cycleLengths[0] * 0.40) + (cycleLengths[1] * 0.60);
    }
    
    final len = cycleLengths.length;
    final weighted = 
        (cycleLengths[len - 3] * 0.10) +
        (cycleLengths[len - 2] * 0.30) +
        (cycleLengths[len - 1] * 0.60);
    
    return weighted;
  }

  /// Extract cycle lengths from period history
  static List<int> getCycleLengths(List<DateTime> history) {
    if (history.length < 2) return [];
    
    final sorted = List<DateTime>.from(history)
      ..sort((a, b) => b.compareTo(a));
    
    List<int> lengths = [];
    for (int i = 0; i < sorted.length - 1; i++) {
      final diff = sorted[i].difference(sorted[i + 1]).inDays;
      if (diff >= 21 && diff <= 45) {
        lengths.add(diff);
      }
    }
    
    return lengths.reversed.toList();
  }

  /// Get weighted average cycle length from period history
  static int calculateWeightedCycleLength(List<DateTime> history) {
    final lengths = getCycleLengths(history);
    if (lengths.isEmpty) return defaultCycleLength;
    
    return calculateWeightedAverage(lengths).round();
  }

  // ============================================================
  // 2. STANDARD DEVIATION - PREDICTION WINDOW
  // ============================================================
  
  static double calculateStandardDeviation(List<int> cycleLengths) {
    if (cycleLengths.length < 2) return 0.0;
    
    final mean = cycleLengths.reduce((a, b) => a + b) / cycleLengths.length;
    
    double sumSquaredDiff = 0;
    for (final length in cycleLengths) {
      sumSquaredDiff += pow(length - mean, 2);
    }
    final variance = sumSquaredDiff / cycleLengths.length;
    
    return sqrt(variance);
  }

  static int getPredictionBufferDays(List<DateTime> history) {
    final lengths = getCycleLengths(history);
    if (lengths.length < 2) return 2;
    
    final stdDev = calculateStandardDeviation(lengths);
    
    if (stdDev <= 1.5) return 1;
    if (stdDev <= 2.5) return 2;
    if (stdDev <= 3.5) return 3;
    return 4;
  }

  static String getCycleRegularity(List<DateTime> history) {
    final lengths = getCycleLengths(history);
    if (lengths.length < 3) return 'Not enough data';
    
    final stdDev = calculateStandardDeviation(lengths);
    
    if (stdDev <= 1.5) return '🎯 Very Regular';
    if (stdDev <= 2.5) return '✓ Regular';
    if (stdDev <= 3.5) return '↔ Somewhat Variable';
    return '⚠ Irregular';
  }

  // ============================================================
  // 3. STRESS FACTOR ADJUSTMENT
  // ============================================================
  
  static int getStressAdjustment(List<String> currentSymptoms) {
    if (currentSymptoms.contains('high_stress')) {
      return 2;
    }
    if (currentSymptoms.contains('sick')) {
      return 3;
    }
    return 0;
  }

  // ============================================================
  // 4. DYNAMIC LUTEAL PHASE (God-Tier #1)
  // ============================================================
  
  /// Calculate personal luteal phase length from ovulation markers
  /// 
  /// If she logs "Egg White Fluid" or "Positive OPK" on Day 16,
  /// and her period comes Day 28, her luteal phase = 12 days
  static int calculatePersonalLutealLength(
    List<DateTime> periodHistory,
    List<Map<String, dynamic>> ovulationMarkers,
  ) {
    if (periodHistory.length < 2 || ovulationMarkers.isEmpty) {
      return defaultLutealLength;
    }
    
    List<int> lutealLengths = [];
    
    // Sort period history (newest first)
    final sortedPeriods = List<DateTime>.from(periodHistory)
      ..sort((a, b) => b.compareTo(a));
    
    // For each ovulation marker, find the next period
    for (final marker in ovulationMarkers) {
      final ovulationDate = marker['date'] as DateTime;
      
      // Find the next period after this ovulation
      for (final periodDate in sortedPeriods) {
        if (periodDate.isAfter(ovulationDate)) {
          final lutealDays = periodDate.difference(ovulationDate).inDays;
          
          // Valid luteal phase is 10-16 days
          if (lutealDays >= 10 && lutealDays <= 16) {
            lutealLengths.add(lutealDays);
            break;
          }
        }
      }
    }
    
    if (lutealLengths.isEmpty) return defaultLutealLength;
    
    // Return average of last 3 luteal phases
    final recentLuteal = lutealLengths.take(3).toList();
    return (recentLuteal.reduce((a, b) => a + b) / recentLuteal.length).round();
  }

  // ============================================================
  // 5. SYMPTOM PATTERN RECOGNITION (God-Tier #2)
  // ============================================================
  
  /// Analyze if a symptom typically occurs before period
  /// 
  /// Returns days before period if correlated, null if not
  static int? getSymptomPeriodCorrelation(
    String symptom,
    List<DateTime> periodHistory,
    List<Map<String, dynamic>> symptomHistory,
  ) {
    if (periodHistory.length < 3 || symptomHistory.isEmpty) return null;
    
    // Sort periods (newest first)
    final sortedPeriods = List<DateTime>.from(periodHistory)
      ..sort((a, b) => b.compareTo(a));
    
    // Get symptom occurrences for this symptom
    final symptomDates = symptomHistory
        .where((s) => s['symptom'] == symptom)
        .map((s) => s['date'] as DateTime)
        .toList();
    
    if (symptomDates.isEmpty) return null;
    
    // Check correlation: how many days before period did this symptom occur?
    List<int> daysBeforePeriod = [];
    
    for (final periodDate in sortedPeriods.take(3)) {
      for (final symptomDate in symptomDates) {
        final daysBefore = periodDate.difference(symptomDate).inDays;
        
        // Check if symptom occurred 1-5 days before period
        if (daysBefore >= 1 && daysBefore <= 5) {
          daysBeforePeriod.add(daysBefore);
          break; // Only count once per period
        }
      }
    }
    
    // Need at least 2 occurrences to establish pattern
    if (daysBeforePeriod.length >= 2) {
      // Return average days before period
      return (daysBeforePeriod.reduce((a, b) => a + b) / daysBeforePeriod.length).round();
    }
    
    return null;
  }

  /// Check if current symptoms suggest period is imminent
  static Map<String, dynamic>? checkSymptomPrediction(
    List<String> currentSymptoms,
    int currentDay,
    int cycleLength,
    List<DateTime> periodHistory,
    List<Map<String, dynamic>> symptomHistory,
  ) {
    // Only check in late luteal phase (after day 20 typically)
    if (currentDay < cycleLength - 8) return null;
    
    for (final symptom in currentSymptoms) {
      final correlation = getSymptomPeriodCorrelation(
        symptom,
        periodHistory,
        symptomHistory,
      );
      
      if (correlation != null) {
        final symptomData = Symptom.values.firstWhere(
          (s) => s.name == symptom,
          orElse: () => Symptom.headache,
        );
        
        return {
          'symptom': symptom,
          'emoji': symptomData.emoji,
          'label': symptomData.label,
          'days_until_period': correlation,
          'predicted_date': DateTime.now().add(Duration(days: correlation)),
          'message': 'Based on your ${symptomData.label.toLowerCase()}, period likely starts in $correlation ${correlation == 1 ? "day" : "days"}.',
        };
      }
    }
    
    return null;
  }

  // ============================================================
  // 6. GHOST PERIOD DETECTION (God-Tier #3)
  // ============================================================
  
  /// Check if we should show "Did your period start?" popup
  /// 
  /// Returns the predicted date if we think she forgot to log
  static DateTime? checkGhostPeriod(
    DateTime? lastPeriodStart,
    int cycleLength,
    int bufferDays,
  ) {
    if (lastPeriodStart == null) return null;
    
    final predictedDate = lastPeriodStart.add(Duration(days: cycleLength));
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    
    // If predicted date has passed by 1-3 days, she might have forgotten to log
    final daysPastPredicted = todayOnly.difference(predictedDate).inDays;
    
    // Only trigger if 1-5 days past predicted, not too late
    if (daysPastPredicted >= 1 && daysPastPredicted <= 5) {
      return predictedDate;
    }
    
    return null;
  }

  // ============================================================
  // PHASE DETECTION
  // ============================================================
  
  static String calculatePhase(int currentDay, {required int cycleLength, int? lutealLength}) {
    final luteal = lutealLength ?? defaultLutealLength;
    final ovulationDay = cycleLength - luteal;
    
    if (currentDay <= 5) {
      return 'menstruation';
    } else if (currentDay < ovulationDay - 2) {
      return 'follicular';
    } else if (currentDay <= ovulationDay + 2) {
      return 'ovulation';
    } else if (currentDay <= cycleLength) {
      return 'luteal';
    } else {
      return 'late';
    }
  }

  static Map<String, dynamic> getPhaseData(String phaseKey) {
    return phases[phaseKey] ?? phases['menstruation']!;
  }

  static int calculateCurrentDay(DateTime lastPeriodStart) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDate = DateTime(
      lastPeriodStart.year,
      lastPeriodStart.month,
      lastPeriodStart.day,
    );
    
    final difference = today.difference(startDate).inDays + 1;
    return difference < 1 ? 1 : difference;
  }

  static DateTime predictNextPeriod(DateTime lastPeriodStart, {required int cycleLength}) {
    return lastPeriodStart.add(Duration(days: cycleLength));
  }

  static int daysUntilNextPeriod(DateTime lastPeriodStart, {required int cycleLength}) {
    final nextPeriod = predictNextPeriod(lastPeriodStart, cycleLength: cycleLength);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return nextPeriod.difference(today).inDays;
  }

  // ============================================================
  // MAIN METHOD - GET COMPLETE CYCLE INFO
  // ============================================================
  
  static CycleInfo getCycleInfo(DateTime? lastPeriodStart, {
    int? cycleLength,
    int? personalLutealLength,
    List<DateTime>? periodHistory,
    List<String>? currentSymptoms,
    List<Map<String, dynamic>>? symptomHistory,
    List<Map<String, dynamic>>? ovulationMarkers,
  }) {
    if (lastPeriodStart == null) {
      return CycleInfo.empty();
    }
    
    final symptoms = currentSymptoms ?? [];
    final history = periodHistory ?? [];
    final symHistory = symptomHistory ?? [];
    final ovMarkers = ovulationMarkers ?? [];
    
    // SMART: Use weighted average from history
    final avgCycleLength = cycleLength ?? 
        (history.isNotEmpty 
            ? calculateWeightedCycleLength(history)
            : defaultCycleLength);
    
    // GOD-TIER #1: Dynamic luteal phase
    final lutealLength = personalLutealLength ?? 
        calculatePersonalLutealLength(history, ovMarkers);
    
    // SMART: Adjust for stress
    final stressAdjustment = getStressAdjustment(symptoms);
    final adjustedCycleLength = avgCycleLength + stressAdjustment;
    
    // SMART: Calculate prediction window
    final bufferDays = getPredictionBufferDays(history);
    final cycleLengths = getCycleLengths(history);
    final stdDev = cycleLengths.length >= 2 
        ? calculateStandardDeviation(cycleLengths) 
        : 0.0;
    
    final currentDay = calculateCurrentDay(lastPeriodStart);
    final phaseKey = calculatePhase(currentDay, cycleLength: adjustedCycleLength, lutealLength: lutealLength);
    final phaseData = getPhaseData(phaseKey);
    final nextPeriod = predictNextPeriod(lastPeriodStart, cycleLength: adjustedCycleLength);
    final daysUntil = daysUntilNextPeriod(lastPeriodStart, cycleLength: adjustedCycleLength);
    
    // Calculate ovulation day with personal luteal length
    final ovulationDay = adjustedCycleLength - lutealLength;
    
    // Regularity info
    final regularity = getCycleRegularity(history);
    
    // GOD-TIER #2: Symptom pattern prediction
    final symptomPrediction = checkSymptomPrediction(
      symptoms,
      currentDay,
      adjustedCycleLength,
      history,
      symHistory,
    );
    
    // GOD-TIER #3: Ghost period check
    final ghostPeriodDate = checkGhostPeriod(
      lastPeriodStart,
      adjustedCycleLength,
      bufferDays,
    );
    
    return CycleInfo(
      currentDay: currentDay,
      phaseKey: phaseKey,
      phaseName: phaseData['name'] as String,
      phaseEmoji: phaseData['emoji'] as String,
      phaseColor: phaseData['color'] as int,
      phaseDescription: phaseData['description'] as String,
      phaseTip: phaseData['tip'] as String,
      phaseTips: List<String>.from(phaseData['tips'] as List),
      nextPeriodDate: nextPeriod,
      daysUntilNextPeriod: daysUntil,
      cycleLength: avgCycleLength,
      adjustedCycleLength: adjustedCycleLength,
      lastPeriodStart: lastPeriodStart,
      ovulationDay: ovulationDay,
      predictionBufferDays: bufferDays,
      standardDeviation: stdDev,
      cycleRegularity: regularity,
      stressAdjustment: stressAdjustment,
      isStressed: symptoms.contains('high_stress') || symptoms.contains('sick'),
      // NEW God-Tier fields
      personalLutealLength: lutealLength,
      isUsingPersonalLuteal: ovMarkers.isNotEmpty,
      symptomPrediction: symptomPrediction,
      ghostPeriodDate: ghostPeriodDate,
    );
  }
}

/// Data class holding all cycle information
class CycleInfo {
  final int currentDay;
  final String phaseKey;
  final String phaseName;
  final String phaseEmoji;
  final int phaseColor;
  final String phaseDescription;
  final String phaseTip;
  final List<String> phaseTips;
  final DateTime? nextPeriodDate;
  final int daysUntilNextPeriod;
  final int cycleLength;
  final int adjustedCycleLength;
  final DateTime? lastPeriodStart;
  final int ovulationDay;
  final bool isEmpty;
  
  // Prediction window fields
  final int predictionBufferDays;
  final double standardDeviation;
  final String cycleRegularity;
  final int stressAdjustment;
  final bool isStressed;
  
  // God-Tier fields
  final int personalLutealLength;
  final bool isUsingPersonalLuteal;
  final Map<String, dynamic>? symptomPrediction;
  final DateTime? ghostPeriodDate;

  CycleInfo({
    required this.currentDay,
    required this.phaseKey,
    required this.phaseName,
    required this.phaseEmoji,
    required this.phaseColor,
    required this.phaseDescription,
    required this.phaseTip,
    required this.phaseTips,
    required this.nextPeriodDate,
    required this.daysUntilNextPeriod,
    required this.cycleLength,
    required this.adjustedCycleLength,
    required this.lastPeriodStart,
    required this.ovulationDay,
    required this.predictionBufferDays,
    required this.standardDeviation,
    required this.cycleRegularity,
    required this.stressAdjustment,
    required this.isStressed,
    required this.personalLutealLength,
    required this.isUsingPersonalLuteal,
    this.symptomPrediction,
    this.ghostPeriodDate,
    this.isEmpty = false,
  });

  /// Get prediction window as string
  String get predictionWindow {
    if (nextPeriodDate == null) return 'Unknown';
    
    final start = nextPeriodDate!.subtract(Duration(days: predictionBufferDays));
    final end = nextPeriodDate!.add(Duration(days: predictionBufferDays));
    
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    
    if (start.month == end.month) {
      return '${months[start.month - 1]} ${start.day}-${end.day}';
    } else {
      return '${months[start.month - 1]} ${start.day} - ${months[end.month - 1]} ${end.day}';
    }
  }
  
  /// Check if symptom-based prediction is active
  bool get hasSymptomPrediction => symptomPrediction != null;
  
  /// Check if ghost period popup should show
  bool get shouldShowGhostPopup => ghostPeriodDate != null;

  factory CycleInfo.empty() {
    return CycleInfo(
      currentDay: 0,
      phaseKey: 'unknown',
      phaseName: 'No Data',
      phaseEmoji: '❓',
      phaseColor: 0xFF757575,
      phaseDescription: 'No period data logged yet',
      phaseTip: 'Waiting for first period to be logged',
      phaseTips: ['Log your first period to start tracking'],
      nextPeriodDate: null,
      daysUntilNextPeriod: 0,
      cycleLength: 28,
      adjustedCycleLength: 28,
      lastPeriodStart: null,
      ovulationDay: 14,
      predictionBufferDays: 2,
      standardDeviation: 0.0,
      cycleRegularity: 'No data',
      stressAdjustment: 0,
      isStressed: false,
      personalLutealLength: 14,
      isUsingPersonalLuteal: false,
      symptomPrediction: null,
      ghostPeriodDate: null,
      isEmpty: true,
    );
  }
}

/// Symptom types for one-tap logging
enum Symptom {
  headache,
  cramps,
  moodSwing,
  highStress,
  sick,
  // GOD-TIER: Ovulation markers
  eggWhiteFluid,
  positiveOPK,
}

extension SymptomExtension on Symptom {
  String get name {
    switch (this) {
      case Symptom.headache: return 'headache';
      case Symptom.cramps: return 'cramps';
      case Symptom.moodSwing: return 'moodSwing';
      case Symptom.highStress: return 'high_stress';
      case Symptom.sick: return 'sick';
      case Symptom.eggWhiteFluid: return 'egg_white_fluid';
      case Symptom.positiveOPK: return 'positive_opk';
    }
  }
  
  String get emoji {
    switch (this) {
      case Symptom.headache: return '🤕';
      case Symptom.cramps: return '⚡';
      case Symptom.moodSwing: return '😤';
      case Symptom.highStress: return '😰';
      case Symptom.sick: return '🤒';
      case Symptom.eggWhiteFluid: return '💧';
      case Symptom.positiveOPK: return '🧪';
    }
  }
  
  String get label {
    switch (this) {
      case Symptom.headache: return 'Headache';
      case Symptom.cramps: return 'Cramps';
      case Symptom.moodSwing: return 'Mood Swing';
      case Symptom.highStress: return 'Stressed';
      case Symptom.sick: return 'Sick';
      case Symptom.eggWhiteFluid: return 'Fertile Fluid';
      case Symptom.positiveOPK: return 'Ovulation+';
    }
  }
  
  String get boyfriendTip {
    switch (this) {
      case Symptom.headache: 
        return 'She has a headache - keep it quiet and bring water/tea';
      case Symptom.cramps: 
        return 'She\'s having cramps - heating pad + comfort time';
      case Symptom.moodSwing: 
        return 'Mood swing alert - extra patience, don\'t take it personally';
      case Symptom.highStress: 
        return '⚠️ She\'s stressed - period might be delayed. Be extra supportive!';
      case Symptom.sick: 
        return '🏥 She\'s not feeling well - cycle might be affected. Take care of her!';
      case Symptom.eggWhiteFluid: 
        return '✨ Fertile window detected - ovulation is happening now!';
      case Symptom.positiveOPK: 
        return '🧪 Ovulation confirmed by test - peak fertility!';
    }
  }
  
  /// Whether this symptom affects cycle prediction
  bool get affectsCycle {
    return this == Symptom.highStress || this == Symptom.sick;
  }
  
  /// Whether this is an ovulation marker
  bool get isOvulationMarker {
    return this == Symptom.eggWhiteFluid || this == Symptom.positiveOPK;
  }
}
