import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:table_calendar/table_calendar.dart';
import '../utils/cycle_logic.dart';

// Light Turquoise color constants
const Color _primaryTurquoise = Color(0xFF40E0D0);
const Color _darkTurquoise = Color(0xFF00CED1);
const Color _mintCream = Color(0xFFF5FFFA);
const Color _darkText = Color(0xFF1A3A3A);

/// CalendarScreen displays a full calendar view of the menstrual cycle history.
class CalendarScreen extends StatefulWidget {
  final String coupleCode;
  final String? userRole;

  const CalendarScreen({
    super.key,
    required this.coupleCode,
    this.userRole,
  });

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _mintCream,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _darkText),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Cycle Calendar',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: _darkText,
          ),
        ),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE0FFFF), _mintCream, Colors.white],
          ),
        ),
        child: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('couples')
              .doc(widget.coupleCode)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: _primaryTurquoise));
            }

            final data = snapshot.data?.data() as Map<String, dynamic>?;
            final periodHistory = _getPeriodHistory(data);
            final lastPeriodStart = (data?['last_period_start'] as Timestamp?)?.toDate();
            // SMART: Calculate weighted average from actual history
            final avgCycleLength = periodHistory.length >= 2
                ? CycleLogic.calculateWeightedCycleLength(periodHistory)
                : 28;

            return Column(
              children: [
                _buildCalendar(periodHistory, lastPeriodStart, avgCycleLength),
                const SizedBox(height: 16),
                _buildLegend(),
                const SizedBox(height: 16),
                Expanded(child: _buildHistoryList(periodHistory)),
              ],
            );
          },
        ),
      ),
    );
  }

  List<DateTime> _getPeriodHistory(Map<String, dynamic>? data) {
    if (data == null) return [];
    
    final historyList = data['period_history'] as List<dynamic>?;
    if (historyList == null) {
      final lastPeriod = (data['last_period_start'] as Timestamp?)?.toDate();
      return lastPeriod != null ? [lastPeriod] : [];
    }
    
    return historyList
        .map((item) => (item as Timestamp).toDate())
        .toList()
      ..sort((a, b) => b.compareTo(a));
  }

  Widget _buildCalendar(List<DateTime> periodHistory, DateTime? lastPeriodStart, int avgCycleLength) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: TableCalendar(
        firstDay: DateTime.utc(2020, 1, 1),
        lastDay: DateTime.utc(2030, 12, 31),
        focusedDay: _focusedDay,
        calendarFormat: _calendarFormat,
        selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
        onDaySelected: (selectedDay, focusedDay) {
          setState(() {
            _selectedDay = selectedDay;
            _focusedDay = focusedDay;
          });
          _showDayDetails(selectedDay, lastPeriodStart, avgCycleLength);
        },
        onFormatChanged: (format) => setState(() => _calendarFormat = format),
        onPageChanged: (focusedDay) => _focusedDay = focusedDay,
        
        calendarBuilders: CalendarBuilders(
          defaultBuilder: (context, day, focusedDay) => _buildDayCell(day, lastPeriodStart, avgCycleLength, periodHistory),
          todayBuilder: (context, day, focusedDay) => _buildDayCell(day, lastPeriodStart, avgCycleLength, periodHistory, isToday: true),
          selectedBuilder: (context, day, focusedDay) => _buildDayCell(day, lastPeriodStart, avgCycleLength, periodHistory, isSelected: true),
          outsideBuilder: (context, day, focusedDay) => _buildDayCell(day, lastPeriodStart, avgCycleLength, periodHistory, isOutside: true),
        ),
        
        headerStyle: HeaderStyle(
          formatButtonVisible: true,
          titleCentered: true,
          formatButtonDecoration: BoxDecoration(
            color: _primaryTurquoise.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          formatButtonTextStyle: GoogleFonts.poppins(color: _darkTurquoise, fontSize: 12),
          titleTextStyle: GoogleFonts.poppins(color: _darkText, fontSize: 18, fontWeight: FontWeight.w600),
          leftChevronIcon: const Icon(Icons.chevron_left, color: _darkText),
          rightChevronIcon: const Icon(Icons.chevron_right, color: _darkText),
        ),
        
        daysOfWeekStyle: DaysOfWeekStyle(
          weekdayStyle: GoogleFonts.poppins(color: _darkText.withOpacity(0.6), fontSize: 12),
          weekendStyle: GoogleFonts.poppins(color: _darkText.withOpacity(0.4), fontSize: 12),
        ),
        
        calendarStyle: const CalendarStyle(outsideDaysVisible: true),
      ),
    );
  }

  Widget _buildDayCell(DateTime day, DateTime? lastPeriodStart, int avgCycleLength, List<DateTime> periodHistory, {bool isToday = false, bool isSelected = false, bool isOutside = false}) {
    final isPeriodStart = periodHistory.any((d) => isSameDay(d, day));
    
    // Calculate prediction window
    final bufferDays = CycleLogic.getPredictionBufferDays(periodHistory);
    bool isPredictedWindow = false;
    bool isPredictedCenter = false;
    
    if (lastPeriodStart != null) {
      final predictedDate = lastPeriodStart.add(Duration(days: avgCycleLength));
      final windowStart = predictedDate.subtract(Duration(days: bufferDays));
      final windowEnd = predictedDate.add(Duration(days: bufferDays));
      
      // Only show prediction for future dates
      if (day.isAfter(DateTime.now())) {
        isPredictedCenter = isSameDay(day, predictedDate);
        isPredictedWindow = day.isAfter(windowStart.subtract(const Duration(days: 1))) && 
                           day.isBefore(windowEnd.add(const Duration(days: 1)));
      }
    }
    
    Color? phaseColor;
    if (lastPeriodStart != null && !day.isAfter(DateTime.now())) {
      final daysSinceStart = day.difference(lastPeriodStart).inDays + 1;
      if (daysSinceStart >= 1) {
        final cycleDay = ((daysSinceStart - 1) % avgCycleLength) + 1;
        final phase = CycleLogic.calculatePhase(cycleDay, cycleLength: avgCycleLength);
        final phaseData = CycleLogic.getPhaseData(phase);
        phaseColor = Color(phaseData['color'] as int);
      }
    }

    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: isPeriodStart
            ? _primaryTurquoise
            : isPredictedCenter
                ? Colors.red.withOpacity(0.5)
                : isPredictedWindow
                    ? Colors.red.withOpacity(0.15)
                    : isSelected
                        ? _primaryTurquoise.withOpacity(0.2)
                        : phaseColor?.withOpacity(isOutside ? 0.1 : 0.2),
        borderRadius: BorderRadius.circular(8),
        border: isToday
            ? Border.all(color: _primaryTurquoise, width: 2)
            : isPeriodStart
                ? Border.all(color: Colors.white.withOpacity(0.5), width: 1)
                : isPredictedCenter
                    ? Border.all(color: Colors.red, width: 2)
                    : isPredictedWindow
                        ? Border.all(color: Colors.red.withOpacity(0.3), width: 1)
                        : null,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: GoogleFonts.poppins(
                color: isPeriodStart 
                    ? Colors.white 
                    : isPredictedCenter
                        ? Colors.red.shade800
                        : (isOutside ? _darkText.withOpacity(0.3) : _darkText),
                fontWeight: isPeriodStart || isToday || isPredictedCenter ? FontWeight.bold : FontWeight.normal,
                fontSize: 14,
              ),
            ),
            if (isPeriodStart)
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            if (isPredictedCenter && !isPeriodStart)
              const Text('📍', style: TextStyle(fontSize: 8)),
          ],
        ),
      ),
    );
  }

  void _showDayDetails(DateTime day, DateTime? lastPeriodStart, int avgCycleLength) {
    if (lastPeriodStart == null) return;
    
    final daysSinceStart = day.difference(lastPeriodStart).inDays + 1;
    if (daysSinceStart < 1) return;
    
    final cycleDay = ((daysSinceStart - 1) % avgCycleLength) + 1;
    final phase = CycleLogic.calculatePhase(cycleDay, cycleLength: avgCycleLength);
    final phaseData = CycleLogic.getPhaseData(phase);
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: _darkText.withOpacity(0.2), borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 20),
            Text(
              _formatDate(day),
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600, color: _darkText),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(phaseData['emoji'] as String, style: const TextStyle(fontSize: 32)),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Day $cycleDay',
                      style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.bold, color: Color(phaseData['color'] as int)),
                    ),
                    Text(phaseData['name'] as String, style: GoogleFonts.poppins(fontSize: 14, color: _darkText.withOpacity(0.7))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              phaseData['description'] as String,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 13, color: _darkText.withOpacity(0.6)),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
      ),
      child: Column(
        children: [
          // Phase legend
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildLegendItem('🩸', 'Period', const Color(0xFFE53935)),
              _buildLegendItem('🌱', 'Follicular', const Color(0xFF43A047)),
              _buildLegendItem('✨', 'Ovulation', const Color(0xFFFFB300)),
              _buildLegendItem('🍂', 'Luteal', const Color(0xFF8E24AA)),
            ],
          ),
          const SizedBox(height: 10),
          // Prediction legend
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.15),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 6),
                Text('Predicted window', style: GoogleFonts.poppins(fontSize: 10, color: Colors.red.shade700)),
                const SizedBox(width: 12),
                Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.5),
                    border: Border.all(color: Colors.red, width: 2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Center(child: Text('📍', style: TextStyle(fontSize: 6))),
                ),
                const SizedBox(width: 6),
                Text('Expected day', style: GoogleFonts.poppins(fontSize: 10, color: Colors.red.shade700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String emoji, String label, Color color) {
    return Column(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 12))),
        ),
        const SizedBox(height: 4),
        Text(label, style: GoogleFonts.poppins(fontSize: 10, color: _darkText.withOpacity(0.6))),
      ],
    );
  }

  Widget _buildHistoryList(List<DateTime> periodHistory) {
    if (periodHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📅', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('No period history yet', style: GoogleFonts.poppins(color: _darkText.withOpacity(0.5), fontSize: 14)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('Period History', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: _darkText)),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: periodHistory.length,
            itemBuilder: (context, index) {
              final date = periodHistory[index];
              final cycleLength = index < periodHistory.length - 1
                  ? periodHistory[index].difference(periodHistory[index + 1]).inDays
                  : null;
              
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _primaryTurquoise.withOpacity(0.3)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _primaryTurquoise.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(child: Text('🩸', style: TextStyle(fontSize: 20))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_formatDate(date), style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _darkText)),
                          if (cycleLength != null)
                            Text('Cycle length: $cycleLength days', style: GoogleFonts.poppins(fontSize: 12, color: _darkText.withOpacity(0.5))),
                        ],
                      ),
                    ),
                    Text('#${periodHistory.length - index}', style: GoogleFonts.jetBrainsMono(fontSize: 12, color: _darkText.withOpacity(0.3))),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}
