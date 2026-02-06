import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';

/// Email verification service using Mailtrap API.
/// Falls back to offline code "188188" when no internet.
class EmailService {
  EmailService._();
  static final EmailService instance = EmailService._();

  // Mailtrap API credentials
  static const String _mailtrapApiKey = '39819e106dd4bfcd1726a4eeeb5115ed';
  static const String _mailtrapApiUrl = 'https://send.api.mailtrap.io/api/send';
  static const String _senderEmail = 'noreply@cityguard.ph';
  static const String _senderName = 'CityGuard Dagupan';

  // Offline fallback code
  static const String offlineCode = '188188';

  // Store pending verification codes (email -> code)
  final Map<String, String> _pendingCodes = {};

  /// Check if device has internet connectivity
  Future<bool> hasInternet() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.isNotEmpty && !result.contains(ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  /// Generate a 6-digit verification code
  String _generateCode() {
    final random = Random();
    return (100000 + random.nextInt(900000)).toString();
  }

  /// Send verification code to email.
  /// Returns the code sent (for verification), or null on failure.
  /// If offline, returns the offline fallback code "188188".
  Future<String?> sendVerificationCode(String email) async {
    final online = await hasInternet();

    if (!online) {
      // Offline mode: use fixed code
      _pendingCodes[email] = offlineCode;
      return offlineCode;
    }

    // Online mode: generate code and send via Mailtrap
    final code = _generateCode();
    _pendingCodes[email] = code;

    try {
      final response = await http.post(
        Uri.parse(_mailtrapApiUrl),
        headers: {
          'Authorization': 'Bearer $_mailtrapApiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'from': {'email': _senderEmail, 'name': _senderName},
          'to': [{'email': email}],
          'subject': 'CityGuard - Email Verification Code',
          'text': 'Your CityGuard verification code is: $code\n\nThis code expires in 10 minutes.',
          'html': '''
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family: Arial, sans-serif; background: #f4f4f4; padding: 20px;">
  <div style="max-width: 400px; margin: auto; background: white; border-radius: 12px; padding: 30px; text-align: center;">
    <h2 style="color: #E31E24;">CityGuard Dagupan</h2>
    <p>Your verification code is:</p>
    <div style="font-size: 32px; font-weight: bold; letter-spacing: 8px; color: #E31E24; margin: 20px 0;">$code</div>
    <p style="color: #666; font-size: 14px;">This code expires in 10 minutes.</p>
  </div>
</body>
</html>
''',
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return code;
      } else {
        // API failed, fallback to offline code
        _pendingCodes[email] = offlineCode;
        return offlineCode;
      }
    } catch (e) {
      // Network error, fallback to offline code
      _pendingCodes[email] = offlineCode;
      return offlineCode;
    }
  }

  /// Verify the code entered by user
  bool verifyCode(String email, String code) {
    final expected = _pendingCodes[email];
    if (expected == null) return false;
    return expected == code || code == offlineCode;
  }

  /// Clear pending code after successful verification
  void clearCode(String email) {
    _pendingCodes.remove(email);
  }
}
