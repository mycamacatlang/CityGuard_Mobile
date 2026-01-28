import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';

class BottomNav extends StatelessWidget {
  final int currentIndex;

  const BottomNav({super.key, required this.currentIndex});

  void _onTap(int index) {
    if (index == 0) Get.offAllNamed('/home');
    if (index == 1) Get.offAllNamed('/location');
    if (index == 2) Get.offAllNamed('/safetytips');
    if (index == 3) Get.offAllNamed('/account');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _NavItem(icon: Icons.home, label: 'Home', index: 0, currentIndex: currentIndex, onTap: _onTap),
          _NavItem(icon: Icons.location_on, label: 'Location', index: 1, currentIndex: currentIndex, onTap: _onTap),
          _NavItem(icon: Icons.shield, label: 'Safety Tips', index: 2, currentIndex: currentIndex, onTap: _onTap),
          _NavItem(icon: Icons.person, label: 'Account', index: 3, currentIndex: currentIndex, onTap: _onTap),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int index;
  final int currentIndex;
  final Function(int) onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool selected = index == currentIndex;
    final iconColor = selected ? Colors.black : Colors.white;
    // ignore: deprecated_member_use
    final textColor = Colors.white.withOpacity(selected ? 1.0 : 0.95);
    return GestureDetector(
      onTap: () => onTap(index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: textColor, fontSize: 12)),
        ],
      ),
    );
  }
}