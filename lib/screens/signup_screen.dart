import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../services/email_service.dart';
import 'verification_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _pageController = PageController();
  int _currentPage = 0;

  // Account info
  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  // Personal info
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _contactController = TextEditingController();
  final _addressController = TextEditingController();
  final _birthdayController = TextEditingController();
  String? _selectedBarangay;
  String? _selectedGender;

  bool _isLoading = false;

  final List<String> _barangays = [
    'Bacayao Norte', 'Bacayao Sur', 'Barangay I (T. Bugallon)',
    'Barangay II (Nueva)', 'Barangay IV (Zamora)', 'Bolosan',
    'Bonuan Binloc', 'Bonuan Boquig', 'Bonuan Gueset', 'Calmay',
    'Carael', 'Caranglaan', 'Herrero', 'Lasip Chico', 'Lasip Grande',
    'Lomboy', 'Lucao', 'Malued', 'Mamalingling', 'Mangin',
    'Mayombo', 'Pantal', 'Poblacion Oeste', 'Pogo Chico',
    'Pogo Grande', 'Pugaro Suit', 'Salapingao', 'Salisay',
    'Tambac', 'Tapuac', 'Tebeng',
  ];

  @override
  void dispose() {
    _emailController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _contactController.dispose();
    _addressController.dispose();
    _birthdayController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) return 'Email is required';
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value)) return 'Enter a valid email';
    return null;
  }

  String? _validateUsername(String? value) {
    if (value == null || value.isEmpty) return 'Username is required';
    if (value.length < 3) return 'Username must be at least 3 characters';
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
      return 'Only letters, numbers, and underscores';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Password must be at least 8 characters';
    if (!RegExp(r'[A-Z]').hasMatch(value)) return 'Include at least one uppercase letter';
    if (!RegExp(r'[a-z]').hasMatch(value)) return 'Include at least one lowercase letter';
    if (!RegExp(r'[0-9]').hasMatch(value)) return 'Include at least one number';
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  String? _validateRequired(String? value, String field) {
    if (value == null || value.isEmpty) return '$field is required';
    return null;
  }

  String? _validateContact(String? value) {
    if (value == null || value.isEmpty) return 'Contact number is required';
    if (!RegExp(r'^09\d{9}$').hasMatch(value)) {
      return 'Enter valid PH mobile (09XXXXXXXXX)';
    }
    return null;
  }

  void _nextPage() {
    if (_currentPage == 0) {
      // Validate account info
      if (_validateEmail(_emailController.text) != null ||
          _validateUsername(_usernameController.text) != null ||
          _validatePassword(_passwordController.text) != null ||
          _validateConfirmPassword(_confirmPasswordController.text) != null) {
        _formKey.currentState?.validate();
        return;
      }
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _prevPage() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _signup() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_selectedGender == null || _selectedBarangay == null) {
      Get.snackbar(
        'Error',
        'Please select gender and barangay',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    setState(() => _isLoading = true);

    final uid = await AuthService.instance.signUpWithProfile(
      email: _emailController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
      contactNumber: _contactController.text.trim(),
      address: _addressController.text.trim(),
      barangay: _selectedBarangay!,
      birthday: _birthdayController.text.trim(),
      gender: _selectedGender!,
    );

    if (uid == null) {
      setState(() => _isLoading = false);
      Get.snackbar(
        'Error',
        'Username or email already exists',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    // Send verification email
    final email = _emailController.text.trim();
    await EmailService.instance.sendVerificationCode(email);
    AuthService.instance.currentUserId = uid;
    setState(() => _isLoading = false);

    Get.snackbar(
      'Success',
      'Account created! Please verify your email.',
      backgroundColor: AppColors.success,
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
    );
    Get.off(() => VerificationScreen(email: email, userId: uid));
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
          colorScheme: ColorScheme.light(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      _birthdayController.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.primaryGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildProgressIndicator(),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (index) => setState(() => _currentPage = index),
                    children: [
                      _buildAccountPage(),
                      _buildPersonalPage(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _currentPage == 0 ? Get.back() : _prevPage(),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Create Account',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _currentPage == 0 ? 'Step 1: Account Info' : 'Step 2: Personal Info',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: _currentPage >= 1 ? Colors.white : Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: AppColors.elevatedShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTextField(
              controller: _emailController,
              label: 'Email',
              hint: 'your@email.com',
              icon: Icons.email_rounded,
              validator: _validateEmail,
              keyboardType: TextInputType.emailAddress,
            ),
            _buildTextField(
              controller: _usernameController,
              label: 'Username',
              hint: 'Choose a username',
              icon: Icons.alternate_email_rounded,
              validator: _validateUsername,
            ),
            _buildTextField(
              controller: _passwordController,
              label: 'Password',
              hint: 'Create a strong password',
              icon: Icons.lock_rounded,
              validator: _validatePassword,
              obscure: _obscurePassword,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  color: AppColors.grey500,
                ),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            _buildTextField(
              controller: _confirmPasswordController,
              label: 'Confirm Password',
              hint: 'Re-enter your password',
              icon: Icons.lock_outline_rounded,
              validator: _validateConfirmPassword,
              obscure: _obscureConfirm,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  color: AppColors.grey500,
                ),
                onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
              ),
            ),
            const SizedBox(height: 8),
            _buildPasswordHint(),
            const SizedBox(height: 24),
            _buildButton('Continue', _nextPage),
          ],
        ),
      ),
    );
  }

  Widget _buildPersonalPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: AppColors.elevatedShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildTextField(
                    controller: _firstNameController,
                    label: 'First Name',
                    hint: 'Juan',
                    icon: Icons.badge_rounded,
                    validator: (v) => _validateRequired(v, 'First name'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTextField(
                    controller: _lastNameController,
                    label: 'Last Name',
                    hint: 'Dela Cruz',
                    icon: Icons.badge_outlined,
                    validator: (v) => _validateRequired(v, 'Last name'),
                  ),
                ),
              ],
            ),
            _buildTextField(
              controller: _contactController,
              label: 'Contact Number',
              hint: '09XXXXXXXXX',
              icon: Icons.phone_rounded,
              validator: _validateContact,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            ),
            _buildTextField(
              controller: _birthdayController,
              label: 'Birthday',
              hint: 'Select your birthday',
              icon: Icons.cake_rounded,
              readOnly: true,
              onTap: _pickDate,
              validator: (v) => _validateRequired(v, 'Birthday'),
            ),
            _buildDropdown(
              label: 'Gender',
              icon: Icons.wc_rounded,
              value: _selectedGender,
              hint: 'Select gender',
              items: ['Male', 'Female', 'Prefer not to say'],
              onChanged: (v) => setState(() => _selectedGender = v),
            ),
            _buildTextField(
              controller: _addressController,
              label: 'Street Address',
              hint: '123 Rizal Street',
              icon: Icons.home_rounded,
              validator: (v) => _validateRequired(v, 'Address'),
            ),
            _buildDropdown(
              label: 'Barangay',
              icon: Icons.location_on_rounded,
              value: _selectedBarangay,
              hint: 'Select barangay',
              items: _barangays,
              onChanged: (v) => setState(() => _selectedBarangay = v),
            ),
            const SizedBox(height: 24),
            _buildButton(_isLoading ? 'Creating...' : 'Create Account', _isLoading ? null : _signup),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    bool obscure = false,
    bool readOnly = false,
    VoidCallback? onTap,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            obscureText: obscure,
            readOnly: readOnly,
            onTap: onTap,
            validator: validator,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: Icon(icon, color: AppColors.grey500),
              suffixIcon: suffixIcon,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required IconData icon,
    required String? value,
    required String hint,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
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
                      hint: Text(hint, style: TextStyle(color: AppColors.textHint)),
                      isExpanded: true,
                      items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
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

  Widget _buildPasswordHint() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.grey50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Password must contain:', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.grey700, fontSize: 13)),
          const SizedBox(height: 8),
          _passwordRule('At least 8 characters', _passwordController.text.length >= 8),
          _passwordRule('One uppercase letter', RegExp(r'[A-Z]').hasMatch(_passwordController.text)),
          _passwordRule('One lowercase letter', RegExp(r'[a-z]').hasMatch(_passwordController.text)),
          _passwordRule('One number', RegExp(r'[0-9]').hasMatch(_passwordController.text)),
        ],
      ),
    );
  }

  Widget _passwordRule(String text, bool met) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle_rounded : Icons.circle_outlined,
            color: met ? AppColors.success : AppColors.grey400,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: met ? AppColors.success : AppColors.grey500, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback? onPressed) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppColors.primaryShadow,
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: _isLoading && label.contains('Creating')
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_rounded, size: 20, color: Colors.white),
                ],
              ),
      ),
    );
  }
}
