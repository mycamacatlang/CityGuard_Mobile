import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

class CloudinaryService {
  CloudinaryService._();
  static final instance = CloudinaryService._();

  String get _cloudName => dotenv.env['CLOUDINARY_CLOUD_NAME'] ?? '';
  String get _reportPreset => dotenv.env['CLOUDINARY_UPLOAD_PRESET'] ?? '';
  String get _profilePreset => dotenv.env['CLOUDINARY_PROFILE_PRESET'] ?? '';

  String get _imageUploadUrl =>
      'https://api.cloudinary.com/v1_1/$_cloudName/image/upload';

  // ✅ P1 REVISION: Video upload endpoint (live incident video)
  String get _videoUploadUrl =>
      'https://api.cloudinary.com/v1_1/$_cloudName/video/upload';

  Future<String?> _upload(
    String filePath,
    String preset,
    String folder, {
    bool isVideo = false,
  }) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        debugPrint('Cloudinary: file not found at $filePath');
        return null;
      }

      final sizeInMB = file.lengthSync() / (1024 * 1024);
      if (sizeInMB > 20) {
        debugPrint(
          'Cloudinary: file too large (${sizeInMB.toStringAsFixed(1)}MB)',
        );
        return null;
      }

      debugPrint('Cloudinary: uploading to folder=$folder preset=$preset');

      // Force folder by setting public_id with folder prefix
      final uniqueId = const Uuid().v4().replaceAll('-', '').substring(0, 20);
      final publicId = '$folder/$uniqueId';

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(isVideo ? _videoUploadUrl : _imageUploadUrl),
      );
      request.fields['upload_preset'] = preset;
      request.fields['public_id'] = publicId;
      request.fields['resource_type'] = isVideo ? 'video' : 'image';
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final json = jsonDecode(responseBody);

      if (response.statusCode == 200) {
        final secureUrl = json['secure_url'] as String?;
        debugPrint('Cloudinary [$folder] success: $secureUrl');
        return secureUrl;
      } else {
        debugPrint('Cloudinary upload failed: ${json['error']?['message']}');
        return null;
      }
    } catch (e) {
      debugPrint('Cloudinary error: $e');
      return null;
    }
  }

  /// Report images → reports/ folder
  Future<String?> uploadImage(String filePath) async {
    return _upload(filePath, _reportPreset, 'reports');
  }

  /// ✅ P1 REVISION: Report videos → reports/videos folder
  Future<String?> uploadVideo(String filePath) async {
    return _upload(filePath, _reportPreset, 'reports/videos', isVideo: true);
  }

  /// Profile pictures → profiles/ folder
  Future<String?> uploadProfileImage(String filePath) async {
    return _upload(filePath, _profilePreset, 'profiles');
  }
}