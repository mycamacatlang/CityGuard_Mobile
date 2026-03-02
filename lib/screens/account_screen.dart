import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../services/cloudinary_service.dart';
import '../data/schema_constants.dart';
import '../widgets/bottom_nav.dart';
import 'login_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _birthdayController = TextEditingController();
  final _contactController = TextEditingController();
  final _addressController = TextEditingController();
  String? _gender;
  String? _barangay;

  String? _profileImageUrl;
  String? _localImagePath;
  bool _uploadingImage = false;

  String? _email;
  String? _username;
  bool _loading = true;
  bool _saving = false;

  final List<String> _barangays = [
    'Bacayao Norte',
    'Bacayao Sur',
    'Barangay I (T. Bugallon)',
    'Barangay II (Nueva)',
    'Barangay IV (Zamora)',
    'Bolosan',
    'Bonuan Binloc',
    'Bonuan Boquig',
    'Bonuan Gueset',
    'Calmay',
    'Carael',
    'Caranglaan',
    'Herrero',
    'Lasip Chico',
    'Lasip Grande',
    'Lomboy',
    'Lucao',
    'Malued',
    'Mamalingling',
    'Mangin',
    'Mayombo',
    'Pantal',
    'Poblacion Oeste',
    'Pogo Chico',
    'Pogo Grande',
    'Pugaro Suit',
    'Salapingao',
    'Salisay',
    'Tambac',
    'Tapuac',
    'Tebeng',
  ];

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
    final user = await AuthService.instance.getUser(uid);

    if (mounted) {
      setState(() {
        _firstNameController.text =
            profile?[Schema.firstName]?.toString() ?? '';
        _lastNameController.text = profile?[Schema.lastName]?.toString() ?? '';
        _birthdayController.text = profile?[Schema.birthday]?.toString() ?? '';
        _contactController.text =
            profile?[Schema.contactNumber]?.toString() ?? '';
        _addressController.text = profile?[Schema.address]?.toString() ?? '';
        _gender = profile?[Schema.gender]?.toString();
        _barangay = profile?[Schema.barangay]?.toString();
        _profileImageUrl = profile?[Schema.profileImageUrl]?.toString();
        _email = user?[Schema.email]?.toString();
        _username = user?[Schema.username]?.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _birthdayController.dispose();
    _contactController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  // ─── Validators ─────────────────────────────────────────────────────────────

  String? _validateName(String? value, String field) {
    if (value == null || value.trim().isEmpty) return null;
    if (value.trim().length < 2) {
      return '$field must be at least 2 characters';
    }
    if (RegExp(r'[0-9]').hasMatch(value.trim())) {
      return '$field must not contain numbers';
    }
    if (RegExp(r'[!@#\$%^&*()_+=\[\]{};:"|<>?,/\\]').hasMatch(value.trim())) {
      return '$field must not contain special characters';
    }
    if (!RegExp(r'[a-zA-ZÀ-ÿ]').hasMatch(value.trim())) {
      return '$field must contain at least one letter';
    }
    return null;
  }

  String? _validateContact(String? value) {
    if (value == null || value.isEmpty) return null;
    if (!RegExp(r'^09\d{9}$').hasMatch(value)) {
      return 'Enter valid PH mobile (09XXXXXXXXX)';
    }
    return null;
  }

  // ─── Image picker ────────────────────────────────────────────────────────────

  Future<void> _pickImage() async {
    final picker = ImagePicker();

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.grey300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Choose Photo',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _imageSourceOption(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    onTap: () => Navigator.pop(context, ImageSource.camera),
                  ),
                  _imageSourceOption(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );

    if (source == null) return;

    try {
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );

      if (image == null) return;

      setState(() {
        _localImagePath = image.path;
        _uploadingImage = true;
      });

      final url = await CloudinaryService.instance.uploadProfileImage(
        image.path,
      );

      if (url != null) {
        final uid = AuthService.instance.currentUserId;
        if (uid != null) {
          await AuthService.instance.updateProfile(uid, {
            Schema.profileImageUrl: url,
          });
        }
        setState(() {
          _profileImageUrl = url;
          _localImagePath = null;
          _uploadingImage = false;
        });
        Get.snackbar(
          'Photo Updated',
          'Profile picture saved successfully',
          backgroundColor: AppColors.success,
          colorText: Colors.white,
          margin: const EdgeInsets.all(16),
        );
      } else {
        setState(() => _uploadingImage = false);
        Get.snackbar(
          'Upload Failed',
          'Could not save photo. It will only show on this device.',
          backgroundColor: Colors.orange,
          colorText: Colors.white,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        );
      }
    } catch (e) {
      setState(() => _uploadingImage = false);
      Get.snackbar(
        'Error',
        'Could not pick image',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }
  }

  Widget _imageSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: AppColors.primary, size: 32),
          ),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ─── Save ────────────────────────────────────────────────────────────────────

  Future<void> _saveProfile() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;

    setState(() => _saving = true);

    await AuthService.instance.updateProfile(uid, {
      Schema.firstName: _firstNameController.text.trim(),
      Schema.lastName: _lastNameController.text.trim(),
      Schema.birthday: _birthdayController.text.trim(),
      Schema.contactNumber: _contactController.text.trim(),
      Schema.address: _addressController.text.trim(),
      Schema.gender: _gender,
      Schema.barangay: _barangay,
      if (_profileImageUrl != null) Schema.profileImageUrl: _profileImageUrl,
    });

    setState(() => _saving = false);

    if (mounted) {
      Get.snackbar(
        'Success',
        'Profile updated successfully',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }
  }

  void _logout() {
    Get.dialog(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text('Cancel', style: TextStyle(color: AppColors.grey600)),
          ),
          ElevatedButton(
            onPressed: () {
              AuthService.instance.currentUserId = null;
              Get.offAll(() => const LoginScreen());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Logout', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 25),
      firstDate: DateTime(1900),
      lastDate: now,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      _birthdayController.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  // ─── Profile image widget ────────────────────────────────────────────────────

  Widget _buildProfileImage() {
    ImageProvider? imageProvider;
    if (_localImagePath != null) {
      imageProvider = FileImage(File(_localImagePath!));
    } else if (_profileImageUrl != null) {
      imageProvider = NetworkImage(_profileImageUrl!);
    }

    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: CircleAvatar(
            radius: 50,
            backgroundColor: AppColors.grey200,
            backgroundImage: imageProvider,
            child: imageProvider == null
                ? Icon(Icons.person_rounded, size: 50, color: AppColors.grey400)
                : null,
          ),
        ),
        if (_uploadingImage)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        if (!_uploadingImage)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(
                Icons.camera_alt_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
      ],
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : CustomScrollView(
              slivers: [
                _buildAppBar(),
                SliverToBoxAdapter(child: _buildForm()),
              ],
            ),
      bottomNavigationBar: const BottomNav(currentIndex: 3),
    );
  }

  Widget _buildAppBar() {
    final fullName = '${_firstNameController.text} ${_lastNameController.text}'
        .trim();

    return SliverAppBar(
      expandedHeight: 260,
      pinned: true,
      automaticallyImplyLeading: false,
      backgroundColor: AppColors.primary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.logout_rounded, color: Colors.white),
          onPressed: _logout,
        ),
        const SizedBox(width: 8),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: AppColors.primaryGradient,
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(28),
              bottomRight: Radius.circular(28),
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: _uploadingImage ? null : _pickImage,
                  child: _buildProfileImage(),
                ),
                const SizedBox(height: 14),
                Text(
                  fullName.isEmpty ? 'Your Name' : fullName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                if (_email != null)
                  Text(
                    _email!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 14,
                    ),
                  ),
                if (_username != null)
                  Text(
                    '@$_username',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.shield_rounded,
              color: AppColors.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'CityGuard',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Personal Information'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildTextField(
                    controller: _firstNameController,
                    label: 'First Name',
                    icon: Icons.badge_rounded,
                    hint: 'Juan',
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r"[a-zA-ZÀ-ÿ\s\-\.\']"),
                      ),
                    ],
                    validator: (v) => _validateName(v, 'First name'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTextField(
                    controller: _lastNameController,
                    label: 'Last Name',
                    icon: Icons.badge_outlined,
                    hint: 'Dela Cruz',
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r"[a-zA-ZÀ-ÿ\s\-\.\']"),
                      ),
                    ],
                    validator: (v) => _validateName(v, 'Last name'),
                  ),
                ),
              ],
            ),
            _buildTextField(
              controller: _contactController,
              label: 'Contact Number',
              icon: Icons.phone_rounded,
              hint: '09XXXXXXXXX',
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(11),
              ],
              validator: _validateContact,
            ),
            _buildTextField(
              controller: _birthdayController,
              label: 'Birthday',
              icon: Icons.cake_rounded,
              hint: 'YYYY-MM-DD',
              readOnly: true,
              onTap: _pickDate,
            ),
            _buildDropdown(
              'Gender',
              Icons.wc_rounded,
              'Select gender',
              ['Male', 'Female', 'Prefer not to say'],
              _gender,
              (v) => setState(() => _gender = v),
            ),
            const SizedBox(height: 24),
            _sectionTitle('Address Information'),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _addressController,
              label: 'Street Address',
              icon: Icons.home_rounded,
              hint: '123 Rizal Street',
            ),
            _buildDropdown(
              'Barangay',
              Icons.location_on_rounded,
              'Select barangay',
              _barangays,
              _barangay,
              (v) => setState(() => _barangay = v),
            ),
            const SizedBox(height: 32),

            // ═══════════════════════════════════════════════
            //  DEBUG BUTTONS — REMOVE AFTER TESTING
            // ═══════════════════════════════════════════════

            // BUTTON 1 — RED — Test submit without auth
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  await AuthService.instance.logout();
                  try {
                    await AuthService.instance.submitReport({
                      'type': 'Fire',
                      'description': 'This should be blocked completely',
                    });
                    debugPrint('❌ FAIL: submitted without login');
                  } catch (e) {
                    debugPrint('✅ PASS: $e');
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Test: Submit Without Auth',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // BUTTON 2 — ORANGE — Test spoof userId
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    await AuthService.instance.submitReport({
                      'userId': 'FAKE_USER_123',
                      'type': 'Fire',
                      'description': 'Trying to spoof the userId field here',
                    });
                    debugPrint(
                      '✅ Check Firestore — userId should NOT be FAKE_USER_123',
                    );
                  } catch (e) {
                    debugPrint('Blocked: $e');
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Test: Spoof UserId',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // BUTTON 3 — PURPLE — Test delete report
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    final db = FirebaseFirestore.instance;
                    final snap = await db
                        .collection('reports')
                        .where(
                          'userId',
                          isEqualTo: AuthService.instance.currentUserId,
                        )
                        .limit(1)
                        .get();
                    if (snap.docs.isNotEmpty) {
                      await snap.docs.first.reference.delete();
                      debugPrint('❌ FAIL: deleted a report');
                    } else {
                      debugPrint('No reports found — submit a report first');
                    }
                  } catch (e) {
                    debugPrint('✅ PASS: delete blocked — $e');
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Test: Delete Report',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ═══════════════════════════════════════════════
            // END DEBUG BUTTONS
            // ═══════════════════════════════════════════════

            // SAVE CHANGES BUTTON
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppColors.primaryShadow,
              ),
              child: ElevatedButton(
                onPressed: _saving ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Save Changes',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool readOnly = false,
    VoidCallback? onTap,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            readOnly: readOnly,
            onTap: onTap,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            validator: validator,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: Icon(icon, color: AppColors.grey500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown(
    String label,
    IconData icon,
    String hint,
    List<String> items,
    String? value,
    ValueChanged<String?> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.grey100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.grey500),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: value,
                      hint: Text(
                        hint,
                        style: TextStyle(color: AppColors.textHint),
                      ),
                      isExpanded: true,
                      items: items
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: onChanged,
                      dropdownColor: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
