import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/cycle_logic.dart';
import 'login_screen.dart';
import 'calendar_screen.dart';

// Light Turquoise color constants
const Color _primaryTurquoise = Color(0xFF40E0D0);
const Color _darkTurquoise = Color(0xFF00CED1);
const Color _mintCream = Color(0xFFF5FFFA);
const Color _darkText = Color(0xFF1A3A3A);

/// DashboardScreen - The main cycle tracking view
/// 
/// Features SMART MATH:
/// - Calculates average cycle length from history (not fixed 28 days)
/// - Ovulation calculated as 14 days BEFORE next period
/// - Boyfriend-friendly tips that actually help relationships
/// - One-tap symptom buttons for girlfriend
class DashboardScreen extends StatefulWidget {
  final String coupleCode;
  
  const DashboardScreen({super.key, required this.coupleCode});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> 
    with SingleTickerProviderStateMixin {
  String? _userRole;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _loadUserRole();
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadUserRole() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userRole = prefs.getString('user_role');
    });
  }

  Future<void> _showDatePicker() async {
    final now = DateTime.now();
    
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 60)),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _primaryTurquoise,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: _darkText,
            ),
          ),
          child: child!,
        );
      },
    );

    if (selectedDate != null) {
      await FirebaseFirestore.instance
          .collection('couples')
          .doc(widget.coupleCode)
          .update({
        'last_period_start': Timestamp.fromDate(selectedDate),
        'period_history': FieldValue.arrayUnion([Timestamp.fromDate(selectedDate)]),
        'updated_at': FieldValue.serverTimestamp(),
        'current_symptoms': [], // Clear all symptoms when new period starts
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Period logged! 💕 Your partner will see the update.', style: GoogleFonts.poppins()),
            backgroundColor: _primaryTurquoise,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  /// Allow adding past periods to improve history/predictions
  Future<void> _addPastPeriod() async {
    final now = DateTime.now();
    
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: now.subtract(const Duration(days: 28)), // Start looking 1 cycle ago
      firstDate: DateTime(2020),
      lastDate: now,
      helpText: 'SELECT PAST PERIOD DATE',
      confirmText: 'ADD TO HISTORY',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _primaryTurquoise,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: _darkText,
            ),
          ),
          child: child!,
        );
      },
    );

    if (selectedDate != null) {
      // 1. Fetch current data to check against last_period_start
      final doc = await FirebaseFirestore.instance
          .collection('couples')
          .doc(widget.coupleCode)
          .get();
          
      final data = doc.data();
      final currentLastPeriod = (data?['last_period_start'] as Timestamp?)?.toDate();
      
      // 2. Prepare updates
      final Map<String, dynamic> updates = {
        'period_history': FieldValue.arrayUnion([Timestamp.fromDate(selectedDate)]),
        'updated_at': FieldValue.serverTimestamp(),
      };
      
      // 3. Only update "last_period_start" if this new date is NEWER than what we have
      //    (or if we have nothing yet)
      bool updatedCurrent = false;
      if (currentLastPeriod == null || selectedDate.isAfter(currentLastPeriod)) {
        updates['last_period_start'] = Timestamp.fromDate(selectedDate);
        updates['current_symptoms'] = []; // Clear symptoms as this is a new cycle
        updatedCurrent = true;
      }

      await FirebaseFirestore.instance
          .collection('couples')
          .doc(widget.coupleCode)
          .update(updates);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              updatedCurrent 
                  ? 'Current cycle updated! 🩸' 
                  : 'History added! Predictions just got smarter. 🧠',
              style: GoogleFonts.poppins(),
            ),
            backgroundColor: _primaryTurquoise,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  /// Toggle a symptom on/off (supports multiple symptoms)
  /// Also logs to symptom_history for pattern recognition
  Future<void> _toggleSymptom(Symptom symptom, List<String> currentSymptoms) async {
    List<String> updatedSymptoms = List.from(currentSymptoms);
    final isAdding = !updatedSymptoms.contains(symptom.name);
    
    if (isAdding) {
      updatedSymptoms.add(symptom.name);
    } else {
      updatedSymptoms.remove(symptom.name);
    }
    
    // Build update data
    Map<String, dynamic> updateData = {
      'current_symptoms': updatedSymptoms,
      'symptom_logged_at': FieldValue.serverTimestamp(),
    };
    
    // GOD-TIER: Log to symptom_history for pattern recognition
    if (isAdding) {
      final historyEntry = {
        'symptom': symptom.name,
        'date': Timestamp.fromDate(DateTime.now()),
      };
      updateData['symptom_history'] = FieldValue.arrayUnion([historyEntry]);
      
      // GOD-TIER: If ovulation marker, also log to ovulation_markers
      if (symptom.isOvulationMarker) {
        final ovMarker = {
          'type': symptom.name,
          'date': Timestamp.fromDate(DateTime.now()),
        };
        updateData['ovulation_markers'] = FieldValue.arrayUnion([ovMarker]);
      }
    }
    
    await FirebaseFirestore.instance
        .collection('couples')
        .doc(widget.coupleCode)
        .update(updateData);

    if (mounted && isAdding) {
      String message = '${symptom.emoji} ${symptom.label} logged! He\'ll see it.';
      if (symptom.isOvulationMarker) {
        message = '${symptom.emoji} Ovulation marker logged! This will improve predictions.';
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: GoogleFonts.poppins()),
          backgroundColor: symptom.isOvulationMarker ? Colors.amber : _primaryTurquoise,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Clear all symptoms
  Future<void> _clearAllSymptoms() async {
    await FirebaseFirestore.instance
        .collection('couples')
        .doc(widget.coupleCode)
        .update({
      'current_symptoms': [],
    });
  }

  void _openCalendar() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CalendarScreen(
          coupleCode: widget.coupleCode,
          userRole: _userRole,
        ),
      ),
    );
  }

  /// GOD-TIER #3: Ghost Period Popup
  /// Shows when we think she forgot to log her period
  bool _ghostPopupShown = false;
  
  Future<void> _showGhostPeriodPopup(DateTime predictedDate) async {
    // Only show once per session
    if (_ghostPopupShown) return;
    _ghostPopupShown = true;
    
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    
    final dayName = days[predictedDate.weekday - 1];
    final monthName = months[predictedDate.month - 1];
    final dateString = '$dayName, $monthName ${predictedDate.day}';
    
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            const Text('🗓️', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Did your period start?',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: _darkText, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'We expected your period around:',
              style: GoogleFonts.poppins(color: _darkText.withOpacity(0.7)),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: _primaryTurquoise.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _primaryTurquoise.withOpacity(0.3)),
              ),
              child: Text(
                dateString,
                style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: _primaryTurquoise),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Logging the correct date helps keep predictions accurate!',
              style: GoogleFonts.poppins(fontSize: 12, color: _darkText.withOpacity(0.5)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'not_yet'),
            child: Text('No, not yet', style: GoogleFonts.poppins(color: _darkText.withOpacity(0.6))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'yes_correct'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryTurquoise,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('Yes, $dayName!', style: GoogleFonts.poppins(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'different_day'),
            child: Text('Different day...', style: GoogleFonts.poppins(color: _primaryTurquoise)),
          ),
        ],
      ),
    );
    
    if (result == 'yes_correct') {
      // Log the predicted date as period start
      await FirebaseFirestore.instance
          .collection('couples')
          .doc(widget.coupleCode)
          .update({
        'last_period_start': Timestamp.fromDate(predictedDate),
        'period_history': FieldValue.arrayUnion([Timestamp.fromDate(predictedDate)]),
        'updated_at': FieldValue.serverTimestamp(),
        'current_symptoms': [],
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Period logged for $dateString!', style: GoogleFonts.poppins()),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } else if (result == 'different_day') {
      // Open date picker
      _showDatePicker();
    }
    // If 'not_yet', do nothing - period hasn't started
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Disconnect?', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: _darkText)),
        content: Text('Are you sure you want to disconnect from your partner?', style: GoogleFonts.poppins(color: _darkText.withOpacity(0.7))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: _darkText.withOpacity(0.5))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Disconnect', style: GoogleFonts.poppins(color: Colors.red[400])),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('couple_code');
      await prefs.remove('user_role');
      
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const LoginScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE0FFFF), _mintCream, Colors.white],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              children: [
                _buildAppBar(),
                Expanded(
                  child: StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('couples')
                        .doc(widget.coupleCode)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator(color: _primaryTurquoise));
                      }

                      if (snapshot.hasError) {
                        return _buildErrorState(snapshot.error.toString());
                      }

                      final data = snapshot.data?.data() as Map<String, dynamic>?;
                      final lastPeriodStart = (data?['last_period_start'] as Timestamp?)?.toDate();
                      
                      // Get period history for SMART average calculation
                      final historyList = data?['period_history'] as List<dynamic>?;
                      final periodHistory = historyList?.map((t) => (t as Timestamp).toDate()).toList() ?? [];
                      
                      // Current symptoms (supports multiple)
                      final symptomsData = data?['current_symptoms'] as List<dynamic>?;
                      final currentSymptoms = symptomsData?.map((s) => s.toString()).toList() ?? [];
                      
                      // GOD-TIER: Get symptom history for pattern recognition
                      final symptomHistoryData = data?['symptom_history'] as List<dynamic>?;
                      final symptomHistory = symptomHistoryData?.map((s) {
                        final map = s as Map<String, dynamic>;
                        return {
                          'symptom': map['symptom'] as String,
                          'date': (map['date'] as Timestamp).toDate(),
                        };
                      }).toList() ?? [];
                      
                      // GOD-TIER: Get ovulation markers for dynamic luteal phase
                      final ovMarkersData = data?['ovulation_markers'] as List<dynamic>?;
                      final ovulationMarkers = ovMarkersData?.map((m) {
                        final map = m as Map<String, dynamic>;
                        return {
                          'type': map['type'] as String,
                          'date': (map['date'] as Timestamp).toDate(),
                        };
                      }).toList() ?? [];
                      
                      // GOD-TIER: Calculate using all smart algorithms
                      final cycleInfo = CycleLogic.getCycleInfo(
                        lastPeriodStart,
                        periodHistory: periodHistory,
                        currentSymptoms: currentSymptoms,
                        symptomHistory: symptomHistory,
                        ovulationMarkers: ovulationMarkers,
                      );
                      
                      // GOD-TIER #3: Show ghost period popup if needed (girlfriend only)
                      if (_userRole == 'girlfriend' && cycleInfo.shouldShowGhostPopup) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _showGhostPeriodPopup(cycleInfo.ghostPeriodDate!);
                        });
                      }

                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            // GOD-TIER #2: Symptom-based prediction alert
                            if (cycleInfo.hasSymptomPrediction)
                              _buildSymptomPredictionAlert(cycleInfo.symptomPrediction!),
                            
                            // Symptom Alerts (if active) - Shows for BOYFRIEND
                            if (currentSymptoms.isNotEmpty && _userRole == 'boyfriend')
                              _buildSymptomAlerts(currentSymptoms),
                            
                            // Main phase card
                            _buildPhaseCard(cycleInfo),
                            
                            const SizedBox(height: 16),
                            
                            // Boyfriend Tip Card (prominent!)
                            if (!cycleInfo.isEmpty)
                              _buildBoyfriendTipCard(cycleInfo),
                            
                            const SizedBox(height: 16),
                            
                            // Cycle stats
                            if (!cycleInfo.isEmpty) ...[
                              _buildCycleDayCard(cycleInfo),
                              const SizedBox(height: 16),
                            ],
                            
                            // One-Tap Symptom Buttons (Girlfriend ONLY)
                            if (_userRole == 'girlfriend' && !cycleInfo.isEmpty) ...[
                              _buildSymptomButtons(currentSymptoms),
                              const SizedBox(height: 16),
                            ],
                            
                            // Log Period buttons (Girlfriend only)
                            if (_userRole == 'girlfriend') ...[
                              _buildLogPeriodButton(),
                              const SizedBox(height: 12),
                              _buildAddPastPeriodButton(),
                              const SizedBox(height: 16),
                            ],
                            
                            // Smart cycle info
                            if (!cycleInfo.isEmpty && periodHistory.length >= 2)
                              _buildSmartCycleInfo(cycleInfo, periodHistory.length),
                            
                            const SizedBox(height: 16),
                            _buildSyncStatus(),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text(
                'Us Two',
                style: GoogleFonts.comfortaa(fontSize: 28, fontWeight: FontWeight.bold, color: _darkTurquoise),
              ),
              const SizedBox(width: 8),
              if (_userRole != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _userRole == 'girlfriend' 
                        ? const Color(0xFFFF8A9B).withOpacity(0.2)
                        : _primaryTurquoise.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_userRole == 'girlfriend' ? '👩' : '👨', style: const TextStyle(fontSize: 16)),
                ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.calendar_month, color: _primaryTurquoise),
                onPressed: _openCalendar,
              ),
              IconButton(
                icon: Icon(Icons.logout, color: _darkText.withOpacity(0.5)),
                onPressed: _logout,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Symptom Alert Banners - Shows when she's logged symptoms (supports multiple)
  /// GOD-TIER #2: Symptom-based prediction alert
  Widget _buildSymptomPredictionAlert(Map<String, dynamic> prediction) {
    final emoji = prediction['emoji'] as String;
    final message = prediction['message'] as String;
    final daysUntil = prediction['days_until_period'] as int;
    
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.purple.shade100, Colors.pink.shade100],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purple.shade300, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.purple.withOpacity(0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.8),
              shape: BoxShape.circle,
            ),
            child: Text('🔮', style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Pattern Detected! ',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.purple.shade800,
                      ),
                    ),
                    Text(emoji, style: const TextStyle(fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: GoogleFonts.poppins(fontSize: 12, color: Colors.purple.shade700),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '~$daysUntil ${daysUntil == 1 ? "day" : "days"} until period',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.purple.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSymptomAlerts(List<String> symptomNames) {
    return Column(
      children: symptomNames.map((symptomName) {
        final symptom = Symptom.values.firstWhere(
          (s) => s.name == symptomName,
          orElse: () => Symptom.moodSwing,
        );
        
        // Stress/sick get special orange color (affects cycle)
        final isLifestyleSymptom = symptom.affectsCycle;
        final alertColor = isLifestyleSymptom ? Colors.orange : Colors.amber;
        
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: alertColor.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: alertColor.shade300, width: 2),
          ),
          child: Row(
            children: [
              Text(symptom.emoji, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${symptom.label} Alert!',
                          style: GoogleFonts.poppins(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: alertColor.shade800,
                          ),
                        ),
                        if (isLifestyleSymptom) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade200,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '⚡ Delays cycle',
                              style: GoogleFonts.poppins(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.orange.shade900),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      symptom.boyfriendTip,
                      style: GoogleFonts.poppins(fontSize: 12, color: alertColor.shade700),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPhaseCard(CycleInfo info) {
    final phaseColor = Color(info.phaseColor);
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: phaseColor.withOpacity(0.3), width: 2),
        boxShadow: [
          BoxShadow(color: phaseColor.withOpacity(0.15), blurRadius: 30, offset: const Offset(0, 10)),
        ],
      ),
      child: Column(
        children: [
          Text(info.phaseEmoji, style: const TextStyle(fontSize: 64)),
          const SizedBox(height: 12),
          Text(
            info.phaseName,
            style: GoogleFonts.poppins(fontSize: 26, fontWeight: FontWeight.bold, color: _darkText),
          ),
          if (!info.isEmpty) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: phaseColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Day ${info.currentDay} of ${info.cycleLength}',
                style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: phaseColor),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            info.phaseDescription,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 14, color: _darkText.withOpacity(0.6)),
          ),
          if (info.isEmpty && _userRole == 'girlfriend') ...[
            const SizedBox(height: 12),
            Text(
              '👇 Tap "Log Period" below to start tracking',
              style: GoogleFonts.poppins(fontSize: 12, color: _primaryTurquoise, fontStyle: FontStyle.italic),
            ),
          ],
          if (info.isEmpty && _userRole == 'boyfriend') ...[
            const SizedBox(height: 12),
            Text(
              'Waiting for her to log her first period...',
              style: GoogleFonts.poppins(fontSize: 12, color: _darkText.withOpacity(0.4), fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }

  /// Prominent tip card for boyfriend
  Widget _buildBoyfriendTipCard(CycleInfo info) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_primaryTurquoise.withOpacity(0.1), _primaryTurquoise.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _primaryTurquoise.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('💡', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text(
                _userRole == 'boyfriend' ? 'Pro Tip for You' : 'Current Phase Info',
                style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _darkTurquoise),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            info.phaseTip,
            style: GoogleFonts.poppins(fontSize: 15, color: _darkText, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildCycleDayCard(CycleInfo info) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 5))],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem(
                value: info.daysUntilNextPeriod > 0 
                    ? '${info.daysUntilNextPeriod}' 
                    : info.daysUntilNextPeriod == 0 ? '🔴' : '${info.daysUntilNextPeriod.abs()}',
                label: info.daysUntilNextPeriod > 0 ? 'Days to Period' : info.daysUntilNextPeriod == 0 ? 'Due Today' : 'Days Late',
                icon: Icons.event,
                color: info.daysUntilNextPeriod <= 3 ? Colors.red : _primaryTurquoise,
              ),
              Container(width: 1, height: 50, color: _darkText.withOpacity(0.1)),
              _buildStatItem(
                value: '~${info.cycleLength}',
                label: info.isStressed ? 'Avg (+${info.stressAdjustment}d stress)' : 'Weighted Avg',
                icon: Icons.loop,
                color: _primaryTurquoise,
              ),
            ],
          ),
          // Prediction Window (shows range based on regularity)
          if (info.predictionBufferDays > 1) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.date_range, size: 16, color: Colors.amber),
                  const SizedBox(width: 6),
                  Text(
                    'Expected: ${info.predictionWindow}',
                    style: GoogleFonts.poppins(fontSize: 12, color: Colors.amber.shade800, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
          // Stress adjustment warning
          if (info.isStressed) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '⚠️ Stress detected - prediction adjusted +${info.stressAdjustment} days',
                style: GoogleFonts.poppins(fontSize: 11, color: Colors.orange.shade700),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatItem({required String value, required String label, required IconData icon, required Color color}) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 8),
        Text(value, style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.bold, color: _darkText)),
        Text(label, style: GoogleFonts.poppins(fontSize: 11, color: _darkText.withOpacity(0.5))),
      ],
    );
  }

  /// One-Tap Symptom Buttons for Girlfriend (supports multiple selection)
  Widget _buildSymptomButtons(List<String> currentSymptoms) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('⚡', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Text(
              'Quick Log (he\'ll see this)',
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _darkText.withOpacity(0.7)),
            ),
            if (currentSymptoms.isNotEmpty) ...[
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _primaryTurquoise.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${currentSymptoms.length} active',
                  style: GoogleFonts.poppins(fontSize: 11, color: _darkTurquoise, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        // Row 1: Physical symptoms
        Row(
          children: [
            _buildSymptomButton(Symptom.headache, currentSymptoms),
            const SizedBox(width: 8),
            _buildSymptomButton(Symptom.cramps, currentSymptoms),
            const SizedBox(width: 8),
            _buildSymptomButton(Symptom.moodSwing, currentSymptoms),
          ],
        ),
        const SizedBox(height: 10),
        // Row 2: Cycle-affecting symptoms (stress/sick)
        Row(
          children: [
            _buildSymptomButton(Symptom.highStress, currentSymptoms, affectsCycle: true),
            const SizedBox(width: 8),
            _buildSymptomButton(Symptom.sick, currentSymptoms, affectsCycle: true),
            const Spacer(),
          ],
        ),
        const SizedBox(height: 16),
        // GOD-TIER: Ovulation markers (improves prediction accuracy)
        Row(
          children: [
            const Text('✨', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Text(
              'Ovulation Tracking (improves accuracy)',
              style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.amber.shade700),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildSymptomButton(Symptom.eggWhiteFluid, currentSymptoms, isOvulationMarker: true),
            const SizedBox(width: 8),
            _buildSymptomButton(Symptom.positiveOPK, currentSymptoms, isOvulationMarker: true),
            const Spacer(),
          ],
        ),
        if (currentSymptoms.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _clearAllSymptoms,
            child: Center(
              child: Text(
                'Clear all symptoms',
                style: GoogleFonts.poppins(fontSize: 12, color: _darkText.withOpacity(0.4), decoration: TextDecoration.underline),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSymptomButton(Symptom symptom, List<String> currentSymptoms, {bool affectsCycle = false, bool isOvulationMarker = false}) {
    final isActive = currentSymptoms.contains(symptom.name);
    
    // Different colors for different types
    Color buttonColor;
    if (isOvulationMarker) {
      buttonColor = Colors.amber;
    } else if (affectsCycle) {
      buttonColor = Colors.orange;
    } else {
      buttonColor = _primaryTurquoise;
    }
    
    return Expanded(
      child: GestureDetector(
        onTap: () => _toggleSymptom(symptom, currentSymptoms),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isActive ? buttonColor : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? buttonColor : _darkText.withOpacity(0.15),
              width: isActive ? 2 : 1,
            ),
            boxShadow: isActive ? [
              BoxShadow(color: buttonColor.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4)),
            ] : null,
          ),
          child: Column(
            children: [
              Text(symptom.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 2),
              Text(
                symptom.label,
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: isActive ? Colors.white : _darkText.withOpacity(0.7),
                ),
              ),
              if (isActive)
                const Icon(Icons.check_circle, color: Colors.white, size: 12),
              if (affectsCycle && !isActive)
                Text(
                  'Adjusts cycle',
                  style: GoogleFonts.poppins(fontSize: 8, color: Colors.orange.withOpacity(0.7)),
                ),
              if (isOvulationMarker && !isActive)
                Text(
                  '+Accuracy',
                  style: GoogleFonts.poppins(fontSize: 8, color: Colors.amber.withOpacity(0.8)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogPeriodButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _showDatePicker,
        icon: const Icon(Icons.add_circle_outline),
        label: Text('Log Period Start (Today)', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryTurquoise,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 4,
          shadowColor: _primaryTurquoise.withOpacity(0.4),
        ),
      ),
    );
  }

  Widget _buildAddPastPeriodButton() {
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: _addPastPeriod,
        icon: Icon(Icons.history, color: _primaryTurquoise.withOpacity(0.8), size: 20),
        label: Text('Add Past Cycle Date', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w500, color: _primaryTurquoise)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          backgroundColor: _primaryTurquoise.withOpacity(0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  /// Shows smart cycle info with regularity
  Widget _buildSmartCycleInfo(CycleInfo info, int historyCount) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.auto_awesome, color: Colors.green, size: 16),
              const SizedBox(width: 6),
              Text(
                'Weighted average from $historyCount cycles',
                style: GoogleFonts.poppins(fontSize: 11, color: Colors.green.shade700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                info.cycleRegularity,
                style: GoogleFonts.poppins(fontSize: 12, color: Colors.green.shade800, fontWeight: FontWeight.w600),
              ),
              if (info.standardDeviation > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '(σ = ${info.standardDeviation.toStringAsFixed(1)} days)',
                  style: GoogleFonts.poppins(fontSize: 10, color: Colors.green.shade600),
                ),
              ],
            ],
          ),
          // GOD-TIER: Show personal luteal phase if tracked
          if (info.isUsingPersonalLuteal) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('✨', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 4),
                  Text(
                    'Personal luteal: ${info.personalLutealLength} days',
                    style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.amber.shade800),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSyncStatus() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _primaryTurquoise.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _primaryTurquoise.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: _primaryTurquoise, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text('Live sync with ${_userRole == 'girlfriend' ? 'boyfriend' : 'girlfriend'}', style: GoogleFonts.poppins(fontSize: 12, color: _darkTurquoise)),
          const SizedBox(width: 8),
          Text('• ${widget.coupleCode}', style: GoogleFonts.jetBrainsMono(fontSize: 11, color: _darkText.withOpacity(0.4))),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red[400], size: 48),
            const SizedBox(height: 16),
            Text('Connection Error', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600, color: _darkText)),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, color: _darkText.withOpacity(0.5))),
          ],
        ),
      ),
    );
  }
}
