import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';
import '../services/email_service.dart';
import '../services/auth_service.dart';
import '../data/schema_constants.dart';
import 'home_screen.dart';

class VerificationScreen extends StatefulWidget {
  final String email;
  final String userId;

  const VerificationScreen({
    super.key,
    required this.email,
    required this.userId,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  final List<TextEditingController> _controllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());
  bool _isLoading = false;
  bool _isResending = false;
  bool _isCheckingFirebase = false;

  // Determines which flow to show
  bool get _isRealEmail => AuthService.isRealEmail(widget.email);

  @override
  void dispose() {
    for (var c in _controllers) {
      c.dispose();
    }
    for (var f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String get _code => _controllers.map((c) => c.text).join();

  // --- DUMMY/TEST EMAIL FLOW: verify with code ---
  Future<void> _verify() async {
    if (_code.length != 6) {
      Get.snackbar(
        'Error',
        'Please enter the 6-digit code',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    setState(() => _isLoading = true);

    final verified = EmailService.instance.verifyCode(widget.email, _code);

    if (verified) {
      await AuthService.instance.updateUser(widget.userId, {
        Schema.emailVerified: true,
      });
      EmailService.instance.clearCode(widget.email);

      Get.snackbar(
        'Success',
        'Email verified successfully!',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      Get.offAll(() => const HomeScreen());
    } else {
      Get.snackbar(
        'Error',
        'Invalid verification code',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }

    setState(() => _isLoading = false);
  }

  Future<void> _resendCode() async {
    setState(() => _isResending = true);

    final code = await EmailService.instance.sendVerificationCode(widget.email);

    if (code != null) {
      final isOffline = code == EmailService.offlineCode;
      Get.snackbar(
        'Code Sent',
        isOffline
            ? 'Offline mode: Use code 188188'
            : 'A new verification code has been sent',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
        margin: const EdgeInsets.all(16),
      );
    }

    setState(() => _isResending = false);
  }

  // --- REAL EMAIL FLOW: check Firebase if link was clicked ---
  Future<void> _checkFirebaseVerification() async {
    setState(() => _isCheckingFirebase = true);

    final verified = await AuthService.instance.checkFirebaseEmailVerified();

    if (verified) {
      await AuthService.instance.markEmailVerified(widget.userId);

      Get.snackbar(
        'Success',
        'Email verified successfully!',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      Get.offAll(() => const HomeScreen());
    } else {
      Get.snackbar(
        'Not Verified Yet',
        'Please click the link in your email first, then tap this button.',
        backgroundColor: AppColors.warning,
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
        margin: const EdgeInsets.all(16),
      );
    }

    setState(() => _isCheckingFirebase = false);
  }

  Future<void> _resendFirebaseEmail() async {
    setState(() => _isResending = true);

    try {
      await AuthService.instance.resendVerificationEmail();
      Get.snackbar(
        'Email Sent',
        'A new verification link has been sent to ${widget.email}',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    } catch (e) {
      Get.snackbar(
        'Error',
        'Failed to resend email. Try again later.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }

    setState(() => _isResending = false);
  }

  Widget _buildCodeInput(int index) {
    return Container(
      width: 48,
      height: 60,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _controllers[index].text.isNotEmpty
              ? AppColors.primary
              : AppColors.grey300,
          width: 2,
        ),
        boxShadow: _controllers[index].text.isNotEmpty
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
      child: TextField(
        controller: _controllers[index],
        focusNode: _focusNodes[index],
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        maxLength: 1,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: AppColors.primary,
        ),
        decoration: const InputDecoration(
          counterText: '',
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (value) {
          if (value.isNotEmpty && index < 5) {
            _focusNodes[index + 1].requestFocus();
          } else if (value.isEmpty && index > 0) {
            _focusNodes[index - 1].requestFocus();
          }
          setState(() {});
          if (_code.length == 6) _verify();
        },
      ),
    );
  }

  // --- UI for REAL email (Firebase link flow) ---
  Widget _buildFirebaseVerificationUI() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppColors.elevatedShadow,
          ),
          child: Column(
            children: [
              Icon(Icons.email_outlined, size: 48, color: AppColors.primary),
              const SizedBox(height: 16),
              const Text(
                'Check Your Gmail',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'We sent a verification link to:',
                style: TextStyle(color: AppColors.grey600, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                widget.email,
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Open Gmail, click the verification link, then come back here and tap the button below.',
                style: TextStyle(color: AppColors.grey500, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // I've verified button
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: AppColors.primaryShadow,
                ),
                child: ElevatedButton(
                  onPressed: _isCheckingFirebase
                      ? null
                      : _checkFirebaseVerification,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _isCheckingFirebase
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          "I've Verified My Email",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Resend link button
              TextButton(
                onPressed: _isResending ? null : _resendFirebaseEmail,
                child: _isResending
                    ? Text(
                        'Sending...',
                        style: TextStyle(color: AppColors.grey500),
                      )
                    : Text(
                        'Resend Verification Email',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- UI for DUMMY/TEST email (code input flow) ---
  Widget _buildCodeVerificationUI() {
    return Column(
      children: [
        // Offline hint
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wifi_off_rounded,
                color: Colors.white.withValues(alpha: 0.9),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Offline? Use code: 188188',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),

        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            boxShadow: AppColors.elevatedShadow,
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(6, _buildCodeInput),
              ),
              const SizedBox(height: 32),

              // Verify button
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: AppColors.primaryShadow,
                ),
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _verify,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Verify',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Resend button
              TextButton(
                onPressed: _isResending ? null : _resendCode,
                child: _isResending
                    ? Text(
                        'Sending...',
                        style: TextStyle(color: AppColors.grey500),
                      )
                    : Text(
                        'Resend Code',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icon
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: AppColors.elevatedShadow,
                    ),
                    child: Icon(
                      Icons.mark_email_read_rounded,
                      size: 56,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 32),

                  const Text(
                    'Verify Your Email',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isRealEmail
                        ? 'A verification link was sent to'
                        : 'We sent a verification code to',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.email,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Show the right UI based on email type
                  _isRealEmail
                      ? _buildFirebaseVerificationUI()
                      : _buildCodeVerificationUI(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
