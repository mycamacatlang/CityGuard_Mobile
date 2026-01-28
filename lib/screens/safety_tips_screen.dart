import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../widgets/bottom_nav.dart';

class SafetyTipsScreen extends StatefulWidget {
  const SafetyTipsScreen({super.key});

  @override
  State<SafetyTipsScreen> createState() => _SafetyTipsScreenState();
}

class _SafetyTipsScreenState extends State<SafetyTipsScreen> {
  final List<bool> _expanded = [false, false, false, false];

  Widget _tipCard({
    required String title,
    required int index,
    required String content,
    required IconData icon,
  }) {
    final bool isExpanded = _expanded[index];
    return GestureDetector(
      onTap: () {
        setState(() {
          _expanded[index] = !_expanded[index];
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  child: Icon(icon, color: Colors.orange),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
              ],
            ),
            if (isExpanded) ...[
              const SizedBox(height: 12),
              Text(content),
            ]
          ],
        ),
      ),
    );
  }

  Widget _shieldWithCheck({double size = 44}) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.shield_rounded,
            color: Colors.green[700],
            size: size,
          ),
          Container(
            width: size * 0.45,
            height: size * 0.45,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
          Icon(
            Icons.check,
            color: Colors.green[700],
            size: size * 0.28,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, 
        title: const Text('CITY GUARD', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        elevation: 3,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 12),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _shieldWithCheck(size: 44),
                  const SizedBox(width: 10),
                  const Text('Safety Tips',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    _tipCard(
                      title: 'Earthquake Tips',
                      index: 0,
                      content:
                          'During:\nDrop, Cover and Hold Under a sturdy table.\nStay indoors; avoid windows/glass.\n\nAfter:\nCheck for injuries/gas leaks.\nUse flashlights (not candles).',
                      icon: Icons.warning_amber_rounded,
                    ),
                    _tipCard(
                      title: 'Medical Emergencies Tips',
                      index: 1,
                      content:
                          'Stay calm. Call emergency number.\nCheck responsiveness and breathing.\nIf trained, perform CPR or first aid.\nKeep patient comfortable until help arrives.',
                      icon: Icons.health_and_safety,
                    ),
                    _tipCard(
                      title: 'Fire Tips',
                      index: 2,
                      content:
                          'If fire is small, try to extinguish safely.\nEvacuate immediately if it spreads.\nStay low to avoid smoke; cover nose/mouth.\nCall firefighters and do not re-enter building.',
                      icon: Icons.fire_extinguisher,
                    ),
                    _tipCard(
                      title: 'Floods / Typhoons Tips',
                      index: 3,
                      content:
                          'Move to higher ground immediately.\nAvoid walking or driving through floodwaters.\nSecure important documents and have emergency kit ready.\nFollow local authority evacuation orders.',
                      icon: Icons.water_damage,
                    ),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 2),
    );
  }
}