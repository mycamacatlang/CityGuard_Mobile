import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../widgets/bottom_nav.dart';

class SafetyTipsScreen extends StatefulWidget {
  const SafetyTipsScreen({super.key});

  @override
  State<SafetyTipsScreen> createState() => _SafetyTipsScreenState();
}

class _SafetyTipsScreenState extends State<SafetyTipsScreen> {
  int? _expandedIndex;

  final List<SafetyTip> _tips = [
    SafetyTip(
      title: 'Earthquake Safety',
      icon: Icons.vibration_rounded,
      gradient: [AppColors.fire, const Color(0xFFE74D3D)],
      tips: [
        TipItem(Icons.arrow_downward_rounded, 'DROP to your hands and knees'),
        TipItem(Icons.table_bar_rounded, 'Take COVER under a sturdy table'),
        TipItem(Icons.pan_tool_rounded, 'HOLD ON until shaking stops'),
        TipItem(Icons.door_front_door_rounded, 'Stay away from windows and doors'),
        TipItem(Icons.flashlight_on_rounded, 'Use flashlight, not candles after'),
        TipItem(Icons.local_gas_station_rounded, 'Check for gas leaks'),
      ],
    ),
    SafetyTip(
      title: 'Medical Emergency',
      icon: Icons.medical_services_rounded,
      gradient: [AppColors.medical, const Color(0xFFc0392b)],
      tips: [
        TipItem(Icons.psychology_rounded, 'Stay calm and assess the situation'),
        TipItem(Icons.phone_in_talk_rounded, 'Call emergency services immediately'),
        TipItem(Icons.air_rounded, 'Check breathing and responsiveness'),
        TipItem(Icons.favorite_rounded, 'Perform CPR if trained and needed'),
        TipItem(Icons.accessibility_new_rounded, 'Keep patient comfortable'),
        TipItem(Icons.timer_rounded, 'Note time of incident for responders'),
      ],
    ),
    SafetyTip(
      title: 'Fire Safety',
      icon: Icons.local_fire_department_rounded,
      gradient: [const Color(0xFFe67e22), AppColors.fire],
      tips: [
        TipItem(Icons.fire_extinguisher_rounded, 'Use extinguisher on small fires'),
        TipItem(Icons.directions_run_rounded, 'Evacuate immediately if spreading'),
        TipItem(Icons.south_rounded, 'Stay low to avoid smoke inhalation'),
        TipItem(Icons.masks_rounded, 'Cover nose and mouth with cloth'),
        TipItem(Icons.door_front_door_rounded, 'Feel doors before opening'),
        TipItem(Icons.block_rounded, 'Never re-enter a burning building'),
      ],
    ),
    SafetyTip(
      title: 'Flood & Typhoon',
      icon: Icons.water_rounded,
      gradient: [AppColors.info, const Color(0xFF2980b9)],
      tips: [
        TipItem(Icons.trending_up_rounded, 'Move to higher ground immediately'),
        TipItem(Icons.do_not_step_rounded, 'Avoid walking in floodwaters'),
        TipItem(Icons.no_crash_rounded, 'Do not drive through flooded areas'),
        TipItem(Icons.inventory_2_rounded, 'Prepare emergency kit in advance'),
        TipItem(Icons.folder_copy_rounded, 'Secure important documents'),
        TipItem(Icons.campaign_rounded, 'Follow evacuation orders'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              itemCount: _tips.length,
              itemBuilder: (context, index) {
                return _buildTipCard(_tips[index], index);
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 2),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 12,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
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
              const Text(
                'CityGuard',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.health_and_safety_rounded,
              color: AppColors.success,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Safety Tips',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Learn how to stay safe during emergencies',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTipCard(SafetyTip tip, int index) {
    final isExpanded = _expandedIndex == index;

    return GestureDetector(
      onTap: () {
        setState(() {
          _expandedIndex = isExpanded ? null : index;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: isExpanded ? AppColors.elevatedShadow : AppColors.cardShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: tip.gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(tip.icon, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tip.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${tip.tips.length} safety tips',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ],
                ),
              ),
              // Expanded content
              AnimatedCrossFade(
                firstChild: const SizedBox(width: double.infinity, height: 0),
                secondChild: Container(
                  color: AppColors.surface,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: tip.tips.asMap().entries.map((entry) {
                      return _buildTipItem(entry.value, tip.gradient[0], entry.key == tip.tips.length - 1);
                    }).toList(),
                  ),
                ),
                crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 300),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipItem(TipItem item, Color color, bool isLast) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              item.text,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SafetyTip {
  final String title;
  final IconData icon;
  final List<Color> gradient;
  final List<TipItem> tips;

  SafetyTip({
    required this.title,
    required this.icon,
    required this.gradient,
    required this.tips,
  });
}

class TipItem {
  final IconData icon;
  final String text;

  TipItem(this.icon, this.text);
}
