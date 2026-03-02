import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import '../services/emergency_ai_service.dart';
import '../services/location_service.dart';
import '../services/cloudinary_service.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();

  String? _imagePath;
  bool _analyzing = false;
  bool _submitting = false;
  bool _fetchingLocation = false;
  String? _uploadStatus; // ✅ Shows upload progress to user

  AIClassificationResult? _aiResult;
  LocationResult? _locationResult;
  String? _locationError;

  String _selectedType = 'Accident';
  String? _manualOverrideType;

  final List<String> _incidentTypes = [
    'Accident',
    'Fire',
    'Flood',
    'Crime',
    'Medical Emergency',
    'Others',
  ];

  @override
  void initState() {
    super.initState();
    EmergencyAIService.instance.init();
    _fetchLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  // ─── Location ───────────────────────────────────────────────────────────────

  Future<void> _fetchLocation() async {
    setState(() {
      _fetchingLocation = true;
      _locationError = null;
    });

    final permanentlyDenied = await LocationService.instance
        .isPermissionPermanentlyDenied();

    if (permanentlyDenied) {
      setState(() {
        _fetchingLocation = false;
        _locationError = 'Location permission permanently denied.';
      });
      _showLocationSettingsDialog();
      return;
    }

    final result = await LocationService.instance.getCurrentLocation();

    setState(() {
      _fetchingLocation = false;
      _locationResult = result;
      if (result == null) {
        _locationError = 'Could not get location. Please enable GPS.';
      } else if (!result.isInDagupan) {
        _locationError =
            'You must be within Dagupan City, Pangasinan to submit a report.';
      } else {
        _locationError = null;
      }
    });
  }

  void _showLocationSettingsDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Location Required'),
        content: const Text(
          'Location permission is permanently denied.\n\n'
          'Please enable it in your device settings to submit a report.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              Navigator.pop(context);
              LocationService.instance.openLocationSettings();
            },
            child: const Text(
              'Open Settings',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Validators ─────────────────────────────────────────────────────────────

  String? _validateImage() {
    if (_imagePath == null) return 'A photo is required to submit a report';
    return null;
  }

  String? _validateDescription(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please describe what is happening';
    }
    if (value.trim().length < 20) {
      return 'Description is too short — please provide more detail';
    }
    if (RegExp(r'[<>{}\[\]\\]').hasMatch(value)) {
      return 'Description contains invalid characters';
    }
    return null;
  }

  String? _validateOverride(String? value) {
    if (_aiResult != null &&
        _aiResult!.requiresManualOverride &&
        _manualOverrideType == null) {
      return 'AI confidence is low — please select the correct type';
    }
    return null;
  }

  // ─── Image & AI ─────────────────────────────────────────────────────────────

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (image != null) {
      setState(() {
        _imagePath = image.path;
        _aiResult = null;
        _manualOverrideType = null;
        _uploadStatus = null;
      });
      await _analyzeWithAI();
    }
  }

  Future<void> _analyzeWithAI() async {
    if (_imagePath == null) return;
    setState(() => _analyzing = true);

    try {
      final result = await EmergencyAIService.instance.classifyImage(
        _imagePath!,
      );
      setState(() {
        _aiResult = result;
        _analyzing = false;
        if (!result.requiresManualOverride &&
            _incidentTypes.contains(result.category)) {
          _selectedType = result.category;
        }
        _descriptionController.text = result.description;
      });
    } catch (e) {
      debugPrint('TFLite error: $e');
      setState(() {
        _analyzing = false;
        _aiResult = null;
        _descriptionController.text =
            'Could not analyze image. Please describe the incident manually.';
      });
    }
  }

  // ─── Submit ──────────────────────────────────────────────────────────────────

  Future<void> _submitReport() async {
    // 1. Validate image
    final imageError = _validateImage();
    if (imageError != null) {
      Get.snackbar(
        'Photo Required',
        imageError,
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    // 2. Validate location
    if (_locationResult == null || !_locationResult!.isInDagupan) {
      Get.snackbar(
        'Location Required',
        _locationError ?? 'You must be within Dagupan City to submit a report.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      );
      return;
    }

    // 3. Validate form fields
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _uploadStatus = 'Uploading photo...'; // ✅ Show upload progress
    });

    try {
      // ✅ Step 1: Upload image to Cloudinary first
      String? imageUrl;
      if (_imagePath != null) {
        imageUrl = await CloudinaryService.instance.uploadImage(_imagePath!);
        if (imageUrl == null) {
          // ✅ Upload failed — warn user but still allow submit without image URL
          setState(() => _uploadStatus = null);
          final continueAnyway = await _showUploadFailedDialog();
          if (!continueAnyway) {
            setState(() => _submitting = false);
            return;
          }
        } else {
          setState(() => _uploadStatus = 'Submitting report...');
        }
      }

      final finalType = _manualOverrideType ?? _selectedType;
      final sanitizedDesc = _descriptionController.text.trim().replaceAll(
        RegExp(r'[<>{}\[\]\\]'),
        '',
      );

      // ✅ Step 2: Submit to Firestore with Cloudinary URL (not local path)
      await AuthService.instance.submitReport({
        'userId': AuthService.instance.currentUserId,
        'type': finalType,
        'description': sanitizedDesc,
        'aiCategory': _aiResult?.category,
        'aiConfidence': _aiResult?.confidence,
        'aiOverriddenByUser': _manualOverrideType != null,
        'imageUrl': imageUrl, // ✅ Cloudinary URL or null
        'location': _locationResult!.toMap(), // ✅ Proper map with lat/lng
        'status': 'pending',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });

      setState(() {
        _submitting = false;
        _uploadStatus = null;
      });

      Get.back();
      Get.snackbar(
        'Report Submitted',
        'Your report has been sent to authorities',
        backgroundColor: AppColors.success,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    } catch (e) {
      setState(() {
        _submitting = false;
        _uploadStatus = null;
      });
      Get.snackbar(
        'Error',
        'Failed to submit report. Try again.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }
  }

  // ✅ Ask user if they want to continue without photo URL
  Future<bool> _showUploadFailedDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Photo Upload Failed'),
            content: const Text(
              'The photo could not be uploaded.\n\n'
              'You can still submit the report without the photo, '
              'or cancel and try again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Submit Anyway',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLocationBanner(),
                    const SizedBox(height: 16),
                    _buildPhotoSection(),
                    const SizedBox(height: 20),
                    if (_aiResult != null) _buildAIResult(),
                    const SizedBox(height: 20),
                    _buildIncidentTypeSelector(),
                    const SizedBox(height: 20),
                    _buildDescriptionField(),
                    const SizedBox(height: 32),
                    _buildSubmitButton(),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationBanner() {
    if (_fetchingLocation) {
      return _locationBannerTile(
        icon: Icons.location_searching_rounded,
        color: Colors.blue,
        title: 'Getting your location...',
        subtitle: 'Please wait',
        trailing: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
        ),
      );
    }

    if (_locationError != null) {
      return _locationBannerTile(
        icon: Icons.location_off_rounded,
        color: AppColors.error,
        title: 'Location unavailable',
        subtitle: _locationError!,
        trailing: TextButton(
          onPressed: _fetchLocation,
          child: const Text('Retry', style: TextStyle(fontSize: 12)),
        ),
      );
    }

    if (_locationResult != null && _locationResult!.isInDagupan) {
      return _locationBannerTile(
        icon: Icons.location_on_rounded,
        color: AppColors.success,
        title: 'Location verified',
        subtitle: 'Dagupan City, Pangasinan, Philippines',
        trailing: const Icon(
          Icons.check_circle_rounded,
          color: AppColors.success,
          size: 20,
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _locationBannerTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: color,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 12,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
        boxShadow: AppColors.primaryShadow,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Report Incident',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Dagupan City, Pangasinan only',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Photo Evidence',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 6),
            Text('*', style: TextStyle(color: AppColors.error, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _showImageSourceDialog,
          child: Container(
            width: double.infinity,
            height: 220,
            decoration: BoxDecoration(
              color: AppColors.grey100,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _imagePath != null
                    ? AppColors.primary
                    : AppColors.grey300,
                width: 2,
              ),
            ),
            child: _imagePath != null
                ? Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.file(
                          File(_imagePath!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                      if (_analyzing)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(color: Colors.white),
                                SizedBox(height: 16),
                                Text(
                                  'AI Analyzing...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: GestureDetector(
                          onTap: _showImageSourceDialog,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.edit_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.camera_alt_rounded,
                          color: AppColors.primary,
                          size: 40,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Take or upload a photo',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'AI will automatically detect the incident',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Photo is required',
                        style: TextStyle(
                          color: AppColors.error,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildAIResult() {
    final result = _aiResult!;
    final severityColor = result.severity == 'High'
        ? AppColors.error
        : result.severity == 'Medium'
        ? Colors.orange
        : AppColors.success;
    final confidenceColor = result.requiresManualOverride
        ? Colors.orange
        : AppColors.success;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                color: AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text(
                'AI Analysis',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: severityColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  result.severity,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                'Confidence: ',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: result.confidence,
                    backgroundColor: AppColors.grey300,
                    color: confidenceColor,
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                result.confidenceLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: confidenceColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            result.description,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (result.requiresManualOverride) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Manual override required',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.orange,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _manualOverrideType,
                    decoration: InputDecoration(
                      labelText: 'Select correct incident type *',
                      labelStyle: const TextStyle(fontSize: 13),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: Colors.orange.withValues(alpha: 0.5),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: Colors.orange.withValues(alpha: 0.5),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: _incidentTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    validator: _validateOverride,
                    onChanged: (val) => setState(() {
                      _manualOverrideType = val;
                      if (val != null) _selectedType = val;
                    }),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIncidentTypeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Incident Type',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _incidentTypes.map((type) {
            final isSelected = _selectedType == type;
            return GestureDetector(
              onTap: () => setState(() {
                _selectedType = type;
                if (_manualOverrideType != null) _manualOverrideType = type;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : AppColors.grey100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.grey300,
                  ),
                ),
                child: Text(
                  type,
                  style: TextStyle(
                    color: isSelected ? Colors.white : AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildDescriptionField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Description',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'AI filled',
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _descriptionController,
          maxLines: 4,
          validator: _validateDescription,
          decoration: InputDecoration(
            hintText: 'Describe what is happening...',
            filled: true,
            fillColor: AppColors.grey100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.primary, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: AppColors.error, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 4),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _descriptionController,
          builder: (_, value, __) => Text(
            '${value.text.trim().length} characters (min 20)',
            style: TextStyle(
              fontSize: 11,
              color: value.text.trim().length >= 20
                  ? AppColors.success
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitButton() {
    final locationOk = _locationResult != null && _locationResult!.isInDagupan;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: (_submitting || !locationOk) ? null : _submitReport,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          disabledBackgroundColor: AppColors.grey300,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: _submitting
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // ✅ Shows "Uploading photo..." then "Submitting report..."
                  Text(
                    _uploadStatus ?? 'Submitting...',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.send_rounded,
                    color: locationOk ? Colors.white : AppColors.grey500,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    locationOk
                        ? 'Submit Report'
                        : 'Location required to submit',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: locationOk ? Colors.white : AppColors.grey500,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
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
                'Add Photo',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _photoOption(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    onTap: () {
                      Navigator.pop(context);
                      _pickImage(ImageSource.camera);
                    },
                  ),
                  _photoOption(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    onTap: () {
                      Navigator.pop(context);
                      _pickImage(ImageSource.gallery);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoOption({
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
}
