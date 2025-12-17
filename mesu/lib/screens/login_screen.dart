import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dashboard_screen.dart';

// Light Turquoise color constants
const Color _primaryTurquoise = Color(0xFF40E0D0);
const Color _lightTurquoise = Color(0xFF7FFFD4);
const Color _darkTurquoise = Color(0xFF00CED1);
const Color _mintCream = Color(0xFFF5FFFA);
const Color _darkText = Color(0xFF1A3A3A);

/// LoginScreen handles the role selection and couple code pairing flow.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  String? _selectedRole;
  String? _generatedCode;
  final _codeController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic));
    
    _animationController.forward();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  String _generateCoupleCode() {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const digits = '0123456789';
    final random = Random.secure();
    
    String code = '';
    for (int i = 0; i < 4; i++) {
      code += letters[random.nextInt(letters.length)];
    }
    code += '-';
    for (int i = 0; i < 2; i++) {
      code += digits[random.nextInt(digits.length)];
    }
    
    return code;
  }

  Future<void> _handleGirlfriendFlow() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      String code = _generateCoupleCode();
      final couplesRef = FirebaseFirestore.instance.collection('couples');
      
      DocumentSnapshot doc = await couplesRef.doc(code).get();
      int attempts = 0;
      while (doc.exists && attempts < 10) {
        code = _generateCoupleCode();
        doc = await couplesRef.doc(code).get();
        attempts++;
      }
      
      if (doc.exists) {
        throw Exception('Could not generate unique code. Please try again.');
      }
      
      await couplesRef.doc(code).set({
        'createdAt': FieldValue.serverTimestamp(),
        'girlfriendId': null,
        'boyfriendId': null,
        'isConnected': false,
        'role': 'girlfriend',
        'avg_cycle_length': 28,
      });
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('couple_code', code);
      await prefs.setString('user_role', 'girlfriend');
      
      setState(() {
        _generatedCode = code;
        _isLoading = false;
      });
      
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to create couple code: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleBoyfriendFlow() async {
    final code = _codeController.text.trim().toUpperCase();
    
    if (code.length != 7 || !code.contains('-')) {
      setState(() {
        _errorMessage = 'Please enter a valid code (format: ABCD-12)';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final docRef = FirebaseFirestore.instance.collection('couples').doc(code);
      final doc = await docRef.get();
      
      if (!doc.exists) {
        setState(() {
          _errorMessage = 'Code not found. Please check with your girlfriend.';
          _isLoading = false;
        });
        return;
      }
      
      await docRef.update({
        'boyfriendId': null,
        'isConnected': true,
        'connectedAt': FieldValue.serverTimestamp(),
      });
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('couple_code', code);
      await prefs.setString('user_role', 'boyfriend');
      
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => DashboardScreen(coupleCode: code),
          ),
        );
      }
      
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to connect: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  void _proceedToDashboard() {
    if (_generatedCode != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => DashboardScreen(coupleCode: _generatedCode!),
        ),
      );
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
            colors: [
              Color(0xFFE0FFFF), // Light cyan
              _mintCream,
              Colors.white,
            ],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: SlideTransition(
              position: _slideAnimation,
              child: _buildContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_selectedRole == null) {
      return _buildRoleSelection();
    }
    if (_selectedRole == 'girlfriend') {
      return _buildGirlfriendScreen();
    }
    return _buildBoyfriendScreen();
  }

  Widget _buildRoleSelection() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // App logo/icon
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_primaryTurquoise, _lightTurquoise],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _primaryTurquoise.withOpacity(0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Center(
              child: Text('💕', style: TextStyle(fontSize: 48)),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Us Two',
            style: GoogleFonts.comfortaa(
              fontSize: 42,
              fontWeight: FontWeight.bold,
              color: _darkTurquoise,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sync your cycles together',
            style: GoogleFonts.poppins(
              fontSize: 16,
              color: _darkText.withOpacity(0.6),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 60),
          
          Text(
            'Who are you?',
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: _darkText,
            ),
          ),
          const SizedBox(height: 32),
          
          Row(
            children: [
              Expanded(
                child: _buildRoleCard(
                  role: 'girlfriend',
                  emoji: '👩',
                  label: 'Girlfriend',
                  subtitle: 'Create a code',
                  color: const Color(0xFFFF8A9B), // Soft pink
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildRoleCard(
                  role: 'boyfriend',
                  emoji: '👨',
                  label: 'Boyfriend',
                  subtitle: 'Enter code',
                  color: _primaryTurquoise,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRoleCard({
    required String role,
    required String emoji,
    required String label,
    required String subtitle,
    required Color color,
  }) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedRole = role;
        });
        _animationController.reset();
        _animationController.forward();
        if (role == 'girlfriend') {
          _handleGirlfriendFlow();
        }
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: color.withOpacity(0.3), width: 2),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.2),
              blurRadius: 20,
              spreadRadius: -5,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(emoji, style: const TextStyle(fontSize: 32)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: _darkText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: _darkText.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGirlfriendScreen() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: _darkText),
              onPressed: () {
                setState(() {
                  _selectedRole = null;
                  _generatedCode = null;
                  _errorMessage = null;
                });
                _animationController.reset();
                _animationController.forward();
              },
            ),
          ),
          
          const Spacer(),
          
          if (_isLoading) ...[
            const CircularProgressIndicator(color: _primaryTurquoise),
            const SizedBox(height: 24),
            Text(
              'Creating your love code...',
              style: GoogleFonts.poppins(fontSize: 18, color: _darkText.withOpacity(0.7)),
            ),
          ] else if (_errorMessage != null) ...[
            Icon(Icons.error_outline, color: Colors.red[400], size: 60),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 16, color: Colors.red[400]),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _handleGirlfriendFlow,
              child: const Text('Try Again'),
            ),
          ] else if (_generatedCode != null) ...[
            const Text('💌', style: TextStyle(fontSize: 60)),
            const SizedBox(height: 24),
            Text(
              'Share this code with\nyour boyfriend',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 20,
                color: _darkText.withOpacity(0.7),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 32),
            
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _generatedCode!));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Code copied! 💕', style: GoogleFonts.poppins()),
                    backgroundColor: _primaryTurquoise,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_primaryTurquoise, _lightTurquoise],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: _primaryTurquoise.withOpacity(0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _generatedCode!,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Icon(Icons.copy, color: Colors.white70, size: 24),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tap to copy',
              style: GoogleFonts.poppins(fontSize: 14, color: _darkText.withOpacity(0.4)),
            ),
            const SizedBox(height: 48),
            
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _proceedToDashboard,
                child: Text(
                  'Continue to Dashboard',
                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
          
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildBoyfriendScreen() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: _darkText),
              onPressed: () {
                setState(() {
                  _selectedRole = null;
                  _errorMessage = null;
                  _codeController.clear();
                });
                _animationController.reset();
                _animationController.forward();
              },
            ),
          ),
          
          const Spacer(),
          
          const Text('💝', style: TextStyle(fontSize: 60)),
          const SizedBox(height: 24),
          Text(
            'Enter the code from\nyour girlfriend',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 20,
              color: _darkText.withOpacity(0.7),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 40),
          
          TextField(
            controller: _codeController,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.characters,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
              color: _darkText,
            ),
            decoration: InputDecoration(
              hintText: 'ABCD-12',
              hintStyle: GoogleFonts.jetBrainsMono(
                fontSize: 28,
                color: _darkText.withOpacity(0.2),
                letterSpacing: 4,
              ),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(color: _primaryTurquoise.withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: _primaryTurquoise, width: 2),
              ),
            ),
            inputFormatters: [
              LengthLimitingTextInputFormatter(7),
              TextInputFormatter.withFunction((oldValue, newValue) {
                String text = newValue.text.toUpperCase().replaceAll('-', '');
                if (text.length > 4) {
                  text = '${text.substring(0, 4)}-${text.substring(4)}';
                }
                return TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length),
                );
              }),
            ],
            onSubmitted: (_) => _handleBoyfriendFlow(),
          ),
          
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 14, color: Colors.red[400]),
            ),
          ],
          
          const SizedBox(height: 32),
          
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _handleBoyfriendFlow,
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : Text(
                      'Connect 💕',
                      style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
          
          const Spacer(),
        ],
      ),
    );
  }
}
