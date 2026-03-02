import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import '../data/schema_constants.dart';
import 'signup_screen.dart';
import 'forgot_password_screen.dart';
import 'home_screen.dart';
import 'verification_screen.dart';
import '../services/email_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  int _loginAttempts = 0;
  DateTime? _lockoutEndTime;

  @override
  void initState() {
    super.initState();
    Stream.periodic(const Duration(seconds: 1)).listen((_) {
      if (_lockoutEndTime != null && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _isLockedOut {
    if (_lockoutEndTime == null) return false;
    if (DateTime.now().isBefore(_lockoutEndTime!)) return true;
    _loginAttempts = 0;
    _lockoutEndTime = null;
    return false;
  }

  String get _lockoutTimeRemaining {
    if (_lockoutEndTime == null) return '';
    final remaining = _lockoutEndTime!.difference(DateTime.now());
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '${minutes}m ${seconds}s';
  }

  String? _validateUsername(String? value) {
    if (value == null || value.isEmpty) return 'Please enter your username';
    if (value.length < 3) return 'Username must be at least 3 characters';
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Please enter your password';
    if (value.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  Future<void> _login() async {
    if (_isLockedOut) {
      Get.snackbar(
        'Too Many Attempts',
        'Please wait $_lockoutTimeRemaining before trying again',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        icon: const Icon(Icons.lock_clock, color: Colors.white),
        duration: const Duration(seconds: 4),
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      Get.snackbar(
        'Missing Information',
        'Please fill in all fields correctly',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        icon: const Icon(Icons.error_outline, color: Colors.white),
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    setState(() => _isLoading = true);

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    final uid = await AuthService.instance.login(username, password);

    if (uid == null) {
      _loginAttempts++;

      if (_loginAttempts >= 5) {
        _lockoutEndTime = DateTime.now().add(const Duration(minutes: 10));
        setState(() => _isLoading = false);
        Get.snackbar(
          'Account Temporarily Locked',
          'Too many failed attempts. Try again in 10 minutes.',
          backgroundColor: AppColors.error,
          colorText: Colors.white,
          icon: const Icon(Icons.lock, color: Colors.white),
          duration: const Duration(seconds: 5),
          margin: const EdgeInsets.all(16),
        );
      } else {
        final remaining = 5 - _loginAttempts;
        setState(() => _isLoading = false);
        Get.snackbar(
          'Login Failed',
          'Invalid username or password. $remaining attempt${remaining == 1 ? '' : 's'} remaining.',
          backgroundColor: AppColors.error,
          colorText: Colors.white,
          icon: const Icon(Icons.error_outline, color: Colors.white),
          margin: const EdgeInsets.all(16),
        );
      }
      return;
    }

    _loginAttempts = 0;
    _lockoutEndTime = null;

    final user = await AuthService.instance.getUser(uid);
    final emailVerified = user?[Schema.emailVerified] ?? false;
    final email = user?[Schema.email]?.toString() ?? '';

    AuthService.instance.currentUserId = uid;
    setState(() => _isLoading = false);

    if (!emailVerified && email.isNotEmpty) {
      await EmailService.instance.sendVerificationCode(email);
      Get.snackbar(
        'Email Not Verified',
        'Please verify your email to continue',
        backgroundColor: AppColors.warning,
        colorText: Colors.white,
      );
      Get.off(() => VerificationScreen(email: email, userId: uid));
    } else {
      Get.snackbar(
        'Welcome back!',
        'Logged in as $username',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        icon: const Icon(Icons.check_circle, color: Colors.white),
      );
      Get.off(() => const HomeScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.primaryGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(),
                    const SizedBox(height: 40),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppColors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: AppColors.elevatedShadow,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Welcome Back',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Sign in to continue',
                            style: TextStyle(
                              color: AppColors.grey600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 24),
                          _buildTextField(
                            controller: _usernameController,
                            label: 'Username',
                            hint: 'Enter your username',
                            icon: Icons.person_outline_rounded,
                            validator: _validateUsername,
                          ),
                          const SizedBox(height: 16),
                          _buildTextField(
                            controller: _passwordController,
                            label: 'Password',
                            hint: 'Enter your password',
                            icon: Icons.lock_outline_rounded,
                            obscure: _obscurePassword,
                            validator: _validatePassword,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                color: AppColors.grey500,
                              ),
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                          ),

                          // Lockout banner
                          if (_isLockedOut) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.error.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppColors.error.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lock_clock,
                                    color: AppColors.error,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Too many attempts. Wait $_lockoutTimeRemaining',
                                      style: TextStyle(
                                        color: AppColors.error,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () =>
                                  Get.to(() => const ForgotPasswordScreen()),
                              child: Text(
                                'Forgot Password?',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildPrimaryButton(
                            label: 'Sign In',
                            isLoading: _isLoading,
                            onPressed: _login,
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: Divider(color: AppColors.grey300),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Text(
                                  'or continue with',
                                  style: TextStyle(
                                    color: AppColors.grey500,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Divider(color: AppColors.grey300),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildSocialButton(
                                icon: FontAwesomeIcons.google,
                                color: const Color(0xFFDB4437),
                                onTap: () => Get.snackbar(
                                  'Info',
                                  'Google login coming soon',
                                ),
                              ),
                              const SizedBox(width: 16),
                              _buildSocialButton(
                                icon: FontAwesomeIcons.facebookF,
                                color: const Color(0xFF1877F2),
                                onTap: () => Get.snackbar(
                                  'Info',
                                  'Facebook login coming soon',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          "Don't have an account? ",
                          style: TextStyle(color: Colors.white70),
                        ),
                        GestureDetector(
                          onTap: () => Get.to(() => const SignupScreen()),
                          child: const Text(
                            'Sign up',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              decoration: TextDecoration.underline,
                              decorationColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
              ),
            ],
          ),
          child: Icon(Icons.shield_rounded, color: AppColors.primary, size: 48),
        ),
        const SizedBox(height: 16),
        const Text(
          'CityGuard',
          style: TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'DAGUPAN CITY',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 12,
            letterSpacing: 4,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    bool obscure = false,
    Widget? suffixIcon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, color: AppColors.grey500),
            suffixIcon: suffixIcon,
          ),
        ),
      ],
    );
  }

  Widget _buildPrimaryButton({
    required String label,
    required bool isLoading,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppColors.primaryShadow,
      ),
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_rounded, size: 20),
                ],
              ),
      ),
    );
  }

  Widget _buildSocialButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppColors.grey100,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.grey200),
        ),
        child: Center(child: FaIcon(icon, color: color, size: 22)),
      ),
    );
  }
}
