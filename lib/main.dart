import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/location_screen.dart';
import 'screens/safety_tips_screen.dart';
import 'screens/account_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'City Guard',
      theme: ThemeData(
        primarySwatch: Colors.red,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
      ),
      initialRoute: '/',
      getPages: [
        GetPage(name: '/', page: () => const LoginScreen()),
        GetPage(name: '/home', page: () => const HomeScreen()),
        GetPage(name: '/location', page: () => const LocationScreen()),
        GetPage(name: '/safetytips', page: () => const SafetyTipsScreen()),
        GetPage(name: '/account', page: () => const AccountScreen()),
      ],
      debugShowCheckedModeBanner: false,
    );
  }
}