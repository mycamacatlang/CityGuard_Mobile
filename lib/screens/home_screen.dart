import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';
import '../widgets/bottom_nav.dart';
import '../services/auth_service.dart';
import 'account_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  String _userName = 'User';
  final String _currentLocation = 'Dagupan City, Pangasinan';
  
  bool _isHolding = false;
  bool _showEmergencySelector = false;
  double _swipeOffset = 0;
  int _selectedEmergencyIndex = -1;
  
  late AnimationController _pulseController;
  late AnimationController _holdController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _holdProgress;

  final List<EmergencyType> _emergencyTypes = [
    EmergencyType(
      id: 'medical',
      title: 'Medical',
      subtitle: 'Ambulance & First Aid',
      icon: Icons.local_hospital_rounded,
      color: AppColors.medical,
    ),
    EmergencyType(
      id: 'other',
      title: 'Report',
      subtitle: 'Capture & Report',
      icon: Icons.camera_alt_rounded,
      color: AppColors.fire,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadUserData();
    
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _holdController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    
    _holdProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _holdController, curve: Curves.easeOut),
    );

    _holdController.addStatusListener((status) {
      if (status == AnimationStatus.completed && _isHolding) {
        HapticFeedback.heavyImpact();
        setState(() => _showEmergencySelector = true);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _holdController.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    final uid = AuthService.instance.currentUserId;
    if (uid != null) {
      final profile = await AuthService.instance.getProfile(uid);
      if (mounted && profile != null) {
        setState(() {
          _userName = profile['firstName']?.toString() ?? 'User';
        });
      }
    }
  }

  void _onHelpTap() {
    if (!_showEmergencySelector) {
      HapticFeedback.mediumImpact();
      Get.snackbar(
        'Quick Alert',
        'Hold the button to select emergency type',
        backgroundColor: AppColors.secondary,
        colorText: Colors.white,
        icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.all(16),
      );
    }
  }

  void _onHoldStart(LongPressStartDetails details) {
    setState(() => _isHolding = true);
    _holdController.forward();
    HapticFeedback.lightImpact();
  }

  void _onHoldEnd(LongPressEndDetails details) {
    if (!_showEmergencySelector) {
      _holdController.reverse();
    }
    setState(() => _isHolding = false);
  }

  void _onHorizontalDrag(DragUpdateDetails details) {
    if (_showEmergencySelector) {
      setState(() {
        _swipeOffset += details.delta.dx;
        _swipeOffset = _swipeOffset.clamp(-150.0, 150.0);
        
        if (_swipeOffset < -60) {
          _selectedEmergencyIndex = 0;
        } else if (_swipeOffset > 60) {
          _selectedEmergencyIndex = 1;
        } else {
          _selectedEmergencyIndex = -1;
        }
      });
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_showEmergencySelector && _selectedEmergencyIndex >= 0) {
      HapticFeedback.heavyImpact();
      final selected = _emergencyTypes[_selectedEmergencyIndex];
      _triggerEmergency(selected);
    }
    _resetSelector();
  }

  void _triggerEmergency(EmergencyType type) {
    Get.snackbar(
      '${type.title} Alert',
      'Connecting to emergency services...',
      backgroundColor: type.color,
      colorText: Colors.white,
      icon: Icon(type.icon, color: Colors.white),
      duration: const Duration(seconds: 3),
      margin: const EdgeInsets.all(16),
    );
  }

  void _resetSelector() {
    setState(() {
      _showEmergencySelector = false;
      _swipeOffset = 0;
      _selectedEmergencyIndex = -1;
    });
    _holdController.reset();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          _buildMainContent(),
          if (_showEmergencySelector) _buildOverlay(),
          if (_showEmergencySelector) _buildEmergencySelector(),
        ],
      ),
      bottomNavigationBar: _showEmergencySelector ? null : const BottomNav(currentIndex: 0),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        _buildAppBar(),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                _buildHelpButton(),
                const SizedBox(height: 32),
                _buildInstructions(),
                const Spacer(flex: 3),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 12,
        left: 20,
        right: 20,
        bottom: 16,
      ),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
        boxShadow: AppColors.primaryShadow,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.shield_rounded, color: AppColors.primary, size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'CityGuard',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => Get.to(() => const AccountScreen()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _userName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.person_rounded, color: AppColors.primary, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentLocation,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.95),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.success,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, color: Colors.white, size: 8),
                      SizedBox(width: 4),
                      Text(
                        'Online',
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpButton() {
    return GestureDetector(
      onTap: _onHelpTap,
      onLongPressStart: _onHoldStart,
      onLongPressEnd: _onHoldEnd,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseAnimation, _holdProgress]),
        builder: (context, child) {
          final scale = _isHolding 
              ? 1.0 + (_holdProgress.value * 0.08)
              : _pulseAnimation.value;
          
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.primaryGradient,
                border: Border.all(color: Colors.white, width: 5),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.5),
                    blurRadius: 40,
                    spreadRadius: 5,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer glow ring
                  if (!_isHolding)
                    Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                    ),
                  // Progress ring
                  if (_isHolding && !_showEmergencySelector)
                    SizedBox(
                      width: 180,
                      height: 180,
                      child: CircularProgressIndicator(
                        value: _holdProgress.value,
                        strokeWidth: 4,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                        backgroundColor: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                  // HELP text
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'HELP',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 44,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _isHolding ? 'HOLD...' : 'PRESS',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInstructions() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppColors.cardShadow,
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.touch_app_rounded, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 10),
              const Text(
                'How to use',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _instructionRow(Icons.ads_click_rounded, 'Tap', 'for quick emergency alert'),
          const SizedBox(height: 10),
          _instructionRow(Icons.pan_tool_rounded, 'Hold & Swipe', 'to choose type'),
        ],
      ),
    );
  }

  Widget _instructionRow(IconData icon, String action, String description) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.grey100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.primary, size: 18),
        ),
        const SizedBox(width: 12),
        Text(
          action,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            description,
            style: TextStyle(color: AppColors.grey600, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildOverlay() {
    return GestureDetector(
      onTap: _resetSelector,
      onHorizontalDragUpdate: _onHorizontalDrag,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.black.withValues(alpha: 0.8),
                AppColors.secondary.withValues(alpha: 0.9),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmergencySelector() {
    return GestureDetector(
      onHorizontalDragUpdate: _onHorizontalDrag,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'SWIPE TO SELECT',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose emergency type',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 40),
            
            SizedBox(
              height: 180,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildSwipeOption(0, isLeft: true),
                  _buildCenterIndicator(),
                  _buildSwipeOption(1, isLeft: false),
                ],
              ),
            ),
            
            const SizedBox(height: 40),
            
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close_rounded, color: Colors.white.withValues(alpha: 0.8), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Tap anywhere to cancel',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwipeOption(int index, {required bool isLeft}) {
    final isSelected = _selectedEmergencyIndex == index;
    final type = _emergencyTypes[index];
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: isSelected ? 130 : 100,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isSelected ? type.color : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.3),
          width: isSelected ? 3 : 2,
        ),
        boxShadow: isSelected
            ? [BoxShadow(color: type.color.withValues(alpha: 0.5), blurRadius: 20)]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLeft) Icon(Icons.chevron_left_rounded, color: Colors.white, size: 24),
              Icon(type.icon, color: Colors.white, size: isSelected ? 36 : 28),
              if (!isLeft) Icon(Icons.chevron_right_rounded, color: Colors.white, size: 24),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            type.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: isSelected ? 15 : 13,
            ),
          ),
          if (isSelected) ...[
            const SizedBox(height: 4),
            Text(
              type.subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCenterIndicator() {
    return Container(
      width: 70,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Transform.translate(
            offset: Offset(_swipeOffset * 0.3, 0),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Icon(
                _selectedEmergencyIndex >= 0 
                    ? _emergencyTypes[_selectedEmergencyIndex].icon
                    : Icons.swipe_rounded,
                color: _selectedEmergencyIndex >= 0 
                    ? _emergencyTypes[_selectedEmergencyIndex].color
                    : AppColors.grey500,
                size: 26,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.arrow_back_rounded, color: Colors.white.withValues(alpha: 0.5), size: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'SWIPE',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: Colors.white.withValues(alpha: 0.5), size: 14),
            ],
          ),
        ],
      ),
    );
  }
}

class EmergencyType {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  EmergencyType({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });
}
