import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';
import '../widgets/bottom_nav.dart';

enum EmergencyOption { none, ambulance, police, firefighter }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  EmergencyOption _selectedOption = EmergencyOption.none;

  void _chooseOption(EmergencyOption option) {
    setState(() {
      _selectedOption = option;
    });

    String label = '';
    if (option == EmergencyOption.ambulance) label = 'Call Ambulance selected';
    if (option == EmergencyOption.police) label = 'Call Police selected';
    if (option == EmergencyOption.firefighter) label = 'Call Firefighters selected';

    Get.snackbar(
      'Info',
      label,
      backgroundColor: Colors.black87,
      colorText: Colors.white,
    );
  }

  Widget _buildOption({
    required String title,
    required String subtitle,
    required EmergencyOption option,
    required Widget icon,
  }) {
    final bool selected = _selectedOption == option;
    final bgColor = selected ? AppColors.primary : Colors.white;
    final textColor = selected ? Colors.white : Colors.black;

    return GestureDetector(
      onTap: () => _chooseOption(option),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: Colors.black, width: 1.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(
                      // ignore: deprecated_member_use
                      color: textColor.withOpacity(0.9),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _homeContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'CITY GUARD',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 6),

          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Icon(
                      Icons.warning,
                      color: Colors.black,
                      size: 48, 
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Emergency Assistant',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Choose Below',
                            style: TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),
                
                const Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 14, color: Colors.black),
                    children: [
                      TextSpan(text: 'Emergency calls are for real crises '),
                      TextSpan(
                        text: 'ONLY',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: '.\nMisuse is a crime.'),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          _buildOption(
            title: 'Call Ambulance',
            subtitle: 'For medical emergencies.',
            option: EmergencyOption.ambulance,
            icon: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(Icons.local_hospital, color: Colors.red),
              ),
            ),
          ),

          _buildOption(
            title: 'Call Police',
            subtitle: 'For crimes, accidents, or safety threats.',
            option: EmergencyOption.police,
            icon: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(Icons.directions_car_filled, color: Colors.blue),
              ),
            ),
          ),

          _buildOption(
            title: 'Call Firefighters',
            subtitle: 'For fires or rescue situations.',
            option: EmergencyOption.firefighter,
            icon: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(Icons.fire_truck, color: Colors.orange),
              ),
            ),
          ),

          const SizedBox(height: 90),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.primary,
        elevation: 3,
        title: const Text(
          'CITY GUARD',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(child: _homeContent()),
      bottomNavigationBar: const BottomNav(currentIndex: 0),
    );
  }
}
