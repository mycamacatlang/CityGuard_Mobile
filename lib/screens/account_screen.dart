import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../data/schema_constants.dart';
import '../widgets/bottom_nav.dart';
import 'login_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _birthdayController = TextEditingController();
  String? _gender;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }
    final profile = await AuthService.instance.getProfile(uid);
    if (mounted) {
      setState(() {
        _firstNameController.text = profile?[Schema.firstName]?.toString() ?? '';
        _lastNameController.text = profile?[Schema.lastName]?.toString() ?? '';
        _birthdayController.text = profile?[Schema.birthday]?.toString() ?? '';
        _gender = profile?[Schema.gender]?.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _birthdayController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    await AuthService.instance.updateProfile(uid, {
      Schema.firstName: _firstNameController.text.trim(),
      Schema.lastName: _lastNameController.text.trim(),
      Schema.birthday: _birthdayController.text.trim(),
      Schema.gender: _gender,
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile changes saved')),
      );
    }
  }

  void _logout() {
    AuthService.instance.currentUserId = null;
    Get.offAll(() => const LoginScreen());
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime initial = now;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year + 1),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ), dialogTheme: DialogThemeData(backgroundColor: Colors.white),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (picked != null) {
      setState(() {
        _birthdayController.text = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.primary,
        elevation: 0,
        title: const Text('CITY GUARD', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: _logout,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : Column(
          children: [
            const SizedBox(height: 6),
            const Text(
              'Account',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            CircleAvatar(
              radius: 44,
              backgroundColor: Colors.white,
              child: CircleAvatar(
                radius: 40,
                backgroundColor: Colors.blue[50],
                child: Icon(Icons.person, size: 44, color: Colors.deepPurple[300]),
              ),
            ),

            const SizedBox(height: 18),

            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 14),
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Personal information',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // First Name
                    const Text('First Name', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _buildInputField(
                      controller: _firstNameController,
                      hintText: 'First name',
                      prefix: const Icon(Icons.person, color: Colors.black),
                    ),
                    const SizedBox(height: 12),

                    // Last Name
                    const Text('Last Name', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _buildInputField(
                      controller: _lastNameController,
                      hintText: 'Last name',
                      prefix: const Icon(Icons.person, color: Colors.black),
                    ),
                    const SizedBox(height: 12),

                    // Birthday
                    const Text('Birthday', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _pickDate,
                      child: AbsorbPointer(
                        child: _buildInputField(
                          controller: _birthdayController,
                          hintText: 'YYYY-MM-DD',
                          prefix: const Padding(
                            padding: EdgeInsets.only(left: 8.0, right: 8.0),
                            child: Icon(Icons.calendar_today, color: Colors.black),
                          ),
                          suffix: const Padding(
                            padding: EdgeInsets.only(right: 8.0),
                            child: Icon(Icons.calendar_today, color: Colors.grey),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Gender
                    const Text('Gender', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _buildGenderField(),

                    const SizedBox(height: 18),

                    // Save button 
                    ElevatedButton(
                      onPressed: _loading ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('Save', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 3),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    String? hintText,
    Widget? prefix,
    Widget? suffix,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black, width: 2),
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.black),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: TextStyle(color: Colors.grey[500]),
          prefixIcon: prefix,
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        ),
      ),
    );
  }

  Widget _buildGenderField() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black, width: 2),
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4.0, right: 8.0),
            child: Icon(Icons.wc, color: Colors.black),
          ),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _gender,
                hint: const Text('Select gender', style: TextStyle(color: Colors.black54)),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'male', child: Text('Male')),
                  DropdownMenuItem(value: 'female', child: Text('Female')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                  DropdownMenuItem(value: 'prefer_not', child: Text('Prefer not to say')),
                ],
                onChanged: (v) {
                  setState(() {
                    _gender = v;
                  });
                },
                dropdownColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}