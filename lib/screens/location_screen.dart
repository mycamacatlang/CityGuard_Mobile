import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../widgets/bottom_nav.dart';

class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('CITY GUARD', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        elevation: 3,
      ),
      body: const SafeArea(
        child: Center(child: Text('Location screen (placeholder)')),
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 1),
    );
  }
}