import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import '../services/emergency_ai_service.dart';
import '../services/location_service.dart';
import '../services/cloudinary_service.dart';
import '../constants/app_colors.dart';
import '../services/auth_service.dart';
import 'location_proof_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();

  // ✅ P1 REVISION: Live video (10s max) — gallery uploads DISABLED
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isRecording = false;
  String? _videoPath;
  int _recordSeconds = 0;

  // ✅ P1 REVISION (video-only): video player + frame key so the AI
  // analyzes a frame extracted FROM THE RECORDED VIDEO (never a photo).
  final GlobalKey _videoFrameKey = GlobalKey();
  VideoPlayerController? _videoController;
  bool _isVideoPlaying = false;

  bool _analyzing = false;
  bool _submitting = false;
  bool _fetchingLocation = false;
  String? _uploadStatus;

  AIClassificationResult? _aiResult;
  LocationResult? _locationResult;
  String? _locationError;

  // ✅ P1 REVISION: Dropdown selections (no manual typing for details)
  String _selectedType = 'Accident';
  String _selectedBarangay = 'Poblacion Oeste';
  String _selectedSeverity = 'High';
  DateTime? _lastSubmitTime;

  // ✅ P2 REVISION: Tracks whether the user manually overrode the AI's
  // suggested incident type. Set to true when the user changes the type in
  // the dropdown after AI analysis, so the system knows the user's choice
  // (and its routed department) is what gets submitted.
  bool _aiOverriddenByUser = false;

  // ✅ P1 REVISION: Reporter verification (from logged-in user's profile)
  String _reporterName = '';
  String _reporterPhone = '';

  // ✅ P1 REVISION: Only 5 incident categories (Others removed)
  final List<String> _incidentTypes = [
    'Fire',
    'Flood',
    'Medical Emergency',
    'Accident',
    'Crime',
  ];

  final List<String> _barangays = [
    'Poblacion Oeste', 'Poblacion Este', 'Bacayao Norte', 'Bacayao Sur',
    'Barangay I', 'Barangay II', 'Barangay IV', 'Bolosan',
    'Bonuan Binloc', 'Bonuan Boquig', 'Bonuan Gueset', 'Calmay',
    'Carael', 'Caranglaan', 'Herrero', 'Lasip Chico',
    'Lasip Grande', 'Lomboy', 'Lucao', 'Malued',
    'Mamalingling', 'Mangin', 'Mayombo', 'Pantal',
    'Pogo Chico', 'Pogo Grande', 'Pugaro Suit', 'Salapingao',
    'Salisay', 'Tambac', 'Tapuac', 'Tebeng',
  ];

  final List<String> _severities = ['High', 'Medium', 'Low'];

  // ✅ P1 REVISION: Map an incident type to its assigned department.
  // Used so the "Routed to" label updates when the user changes the type.
  String _departmentFor(String type) {
    switch (type) {
      case 'Fire':
        return 'BFP';
      case 'Flood':
        return 'CDRRMO/MDRRMO';
      case 'Accident':
      case 'Medical Emergency':
        return 'Medical Emergency Team and Responders';
      case 'Crime':
        return 'PNP';
      default:
        return 'CDRRMO/MDRRMO';
    }
  }

  @override
  void initState() {
    super.initState();
    EmergencyAIService.instance.init();
    _fetchLocation();
    _initCamera();
    _loadReporterProfile();
  }

  // ✅ P1 REVISION: Pull reporter name + phone from the logged-in user's profile
  Future<void> _loadReporterProfile() async {
    try {
      final uid = AuthService.instance.currentUserId;
      if (uid == null) return;
      final profile = await AuthService.instance.getProfile(uid);
      if (profile == null || !mounted) return;
      final first = profile['firstName']?.toString() ?? '';
      final last = profile['lastName']?.toString() ?? '';
      setState(() {
        _reporterName = '$first $last'.trim();
        _reporterPhone = profile['contactNumber']?.toString() ?? '';
      });
    } catch (e) {
      debugPrint('Load reporter profile error: $e');
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _cameraController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  // ─── Camera (live video, 10s max) ───────────────────────────────

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;
      final back = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      // ✅ P3 REVISION: Use a lower resolution preset (medium) so the live
      // camera preview runs smoothly on the user's real phone (less lag).
      _cameraController = CameraController(back, ResolutionPreset.medium);
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _startRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      Get.snackbar(
        'Camera Not Ready',
        'Please wait for the camera to initialize.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }
    try {
      await _cameraController!.startVideoRecording();
      setState(() {
        _isRecording = true;
        _recordSeconds = 0;
        _videoPath = null;
        _aiResult = null;
      });
      // ✅ 10-second max recording
      _startTimer();
    } catch (e) {
      debugPrint('Start recording error: $e');
    }
  }

  void _startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !_isRecording) return;
      setState(() => _recordSeconds++);
      if (_recordSeconds >= 10) {
        _stopRecording();
      } else {
        _startTimer();
      }
    });
  }

  Future<void> _stopRecording() async {
    if (_cameraController == null || !_isRecording) return;
    try {
      final file = await _cameraController!.stopVideoRecording();
      setState(() {
        _isRecording = false;
        _videoPath = file.path;
      });
      // ✅ P1 REVISION (video-only): set up the recorded video for playback
      // and extract a frame from it for AI analysis.
      await _setupVideoController();
    } catch (e) {
      debugPrint('Stop recording error: $e');
      setState(() => _isRecording = false);
    }
  }

  // ✅ P1 REVISION (video-only): load the recorded video, render it inside
  // the RepaintBoundary, then extract a frame for the AI classifier.
  Future<void> _setupVideoController() async {
    if (_videoPath == null) return;
    try {
      _videoController?.dispose();
      _videoController = VideoPlayerController.file(File(_videoPath!));
      await _videoController!.initialize();

      // Rebuild the widget tree so the video player is rendered inside the
      // RepaintBoundary (the frame key must have a live context).
      if (mounted) setState(() {});
      await Future.delayed(const Duration(milliseconds: 300));

      // Play briefly so a real frame is rendered, then pause for extraction.
      await _videoController!.play();
      await Future.delayed(const Duration(milliseconds: 500));
      await _videoController!.pause();
      if (mounted) setState(() => _isVideoPlaying = false);

      // Now extract a frame from the recorded video and run AI on it.
      await _extractFrameFromVideo();
    } catch (e) {
      debugPrint('Video controller error: $e');
      if (mounted) setState(() => _analyzing = false);
    }
  }

  // ✅ P1 REVISION (video-only): extract a frame from the RECORDED VIDEO
  // and feed it to the AI classifier. No photo is ever captured or stored.
  // The controller is already set up and rendered by _setupVideoController.
  Future<void> _extractFrameFromVideo() async {
    if (_videoPath == null) return;
    if (mounted) setState(() => _analyzing = true);
    try {
      // Ensure the video is paused at a representative frame.
      if (_videoController != null && _videoController!.value.isInitialized) {
        await _videoController!.seekTo(const Duration(seconds: 1));
        await Future.delayed(const Duration(milliseconds: 300));
      }

      final boundary = _videoFrameKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        debugPrint('RepaintBoundary not found — cannot extract frame');
        if (mounted) setState(() => _analyzing = false);
        return;
      }
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        if (mounted) setState(() => _analyzing = false);
        return;
      }
      final tempDir = await getTemporaryDirectory();
      final frameFile = File(
        '${tempDir.path}/ai_frame_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await frameFile.writeAsBytes(byteData.buffer.asUint8List());

      // Feed the extracted video frame to the AI classifier
      await _analyzeWithAI(frameFile.path);
    } catch (e) {
      debugPrint('Frame extraction error: $e');
      if (mounted) setState(() => _analyzing = false);
    }
  }

  // ─── Location ───────────────────────────────────────────────────

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
            'You must be within the 200km test radius (Region 1 / Pangasinan) '
            'to submit a report.';
      } else {
        _locationError = null;
      }
    });
  }

  // Re-reads the GPS fix so the proof view never shows a stale accuracy.
  Future<void> _openLocationProof(LocationResult current) async {
    var result = current;
    final fresh = await LocationService.instance.getCurrentLocation();
    if (fresh != null) result = fresh;
    if (!mounted) return;
    setState(() {
      _locationResult = result;
      if (result.isInDagupan) _locationError = null;
    });
    Get.to(() => LocationProofScreen(result: result));
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

  // ─── Validators ─────────────────────────────────────────────────

  String? _validateVideo() {
    if (_videoPath == null) return 'A live video is required to submit a report';
    return null;
  }

  String? _validateDescription(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please describe what is happening';
    }
    if (value.trim().length < 20) {
      return 'Description is too short — please provide more detail';
    }
    if (value.trim().length > 500) {
      return 'Description is too long — maximum 500 characters';
    }
    if (RegExp(r'[<>{}\[\]\\]').hasMatch(value)) {
      return 'Description contains invalid characters';
    }
    return null;
  }

  // ─── AI Analysis ────────────────────────────────────────────────

  Future<void> _analyzeWithAI(String framePath) async {
    setState(() => _analyzing = true);

    try {
      // ✅ P1: AI analyzes the captured video frame to detect incident type
      final result = await EmergencyAIService.instance.classifyImage(
        framePath,
      );
      setState(() {
        _aiResult = result;
        _analyzing = false;
        if (!result.isRejected && _incidentTypes.contains(result.category)) {
          _selectedType = result.category;
        }
        // ✅ P2 REVISION: A fresh AI analysis resets the override flag.
        _aiOverriddenByUser = false;
        _descriptionController.text = result.description;
      });
    } catch (e) {
      debugPrint('TFLite error: $e');
      setState(() {
        _analyzing = false;
        _aiResult = null;
        _descriptionController.clear();
      });
    }
  }

  // ─── Submit ─────────────────────────────────────────────────────

  Future<bool> _showSubmitConfirmationDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Submit Report?'),
            content: const Text(
              'This will send your report to authorities. Please review your details before submitting.',
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
                  'Submit',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _submitReport() async {
    // 0. Rate limiting — 30 second cooldown
    if (_lastSubmitTime != null &&
        DateTime.now().difference(_lastSubmitTime!) <
            const Duration(seconds: 30)) {
      Get.snackbar(
        'Please Wait',
        'You can only submit a report every 30 seconds.',
        backgroundColor: Colors.orange,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    // 1. Validate video
    final videoError = _validateVideo();
    if (videoError != null) {
      Get.snackbar(
        'Video Required',
        videoError,
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    // 2. Check file size (max 20MB)
    final file = File(_videoPath!);
    final sizeInMB = file.lengthSync() / (1024 * 1024);
    if (sizeInMB > 20) {
      Get.snackbar(
        'Video Too Large',
        'Please use a video smaller than 20MB.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    // 3. Validate location
    if (_locationResult == null || !_locationResult!.isInDagupan) {
      Get.snackbar(
        'Location Required',
        _locationError ?? 'You must be within the 200km test radius.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      );
      return;
    }

    // 4. ✅ AI confidence gate — only accept 80–100%
    if (_aiResult == null || _aiResult!.isRejected) {
      Get.snackbar(
        'AI Confidence Too Low',
        'AI confidence must be 80–100% to accept the report. '
        'Please record a clearer video.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      );
      return;
    }

    // 5. Sanitize description BEFORE form validation
    final sanitizedDesc = _descriptionController.text.trim().replaceAll(
      RegExp(r'[<>{}\[\]\\]'),
      '',
    );
    _descriptionController.text = sanitizedDesc;

    // 6. Validate form fields
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // 7. Confirm submission
    final confirm = await _showSubmitConfirmationDialog();
    if (!confirm) return;

    // 8. Set rate limit timestamp
    _lastSubmitTime = DateTime.now();

    setState(() {
      _submitting = true;
      _uploadStatus = 'Uploading video...';
    });

    try {
      // Step 1: Upload video to Cloudinary
      String? videoUrl;
      if (_videoPath != null) {
        videoUrl = await CloudinaryService.instance.uploadVideo(_videoPath!);
        if (videoUrl == null) {
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

      // Step 2: Submit — userId NOT sent from client, set server-side
      // ✅ P5 REVISION: When the user overrides the incident type, BOTH
      // `type` and `aiCategory` are set to the user's chosen type so the
      // report stored in Firebase shows the correct type everywhere.
      // When the user does NOT override, keep the AI's original aiCategory.
      final submittedCategory = _aiOverriddenByUser
          ? _selectedType
          : (_aiResult?.category ?? _selectedType);

      await AuthService.instance.submitReport({
        'type': _selectedType,
        'description': sanitizedDesc,
        'aiCategory': submittedCategory,
        'aiConfidence': _aiResult?.confidence,
        // ✅ P2 REVISION: true when the user manually changed the incident
        // type after AI analysis; the user's selected type/barangay/severity
        // and its routed department are what get submitted.
        'aiOverriddenByUser': _aiOverriddenByUser,
        'videoUrl': videoUrl,
        'location': _locationResult!.toMap(),
        'status': 'pending',
        'assignedDepartment': _departmentFor(_selectedType),
        'barangay': _selectedBarangay,
        'severity': _selectedSeverity,
        'createdAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _submitting = false;
        _uploadStatus = null;
      });

      Get.back();
      Get.snackbar(
        'Report Submitted',
        'Your report has been sent to ${_aiResult?.department ?? 'authorities'}',
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

  // ─── Upload Failed Dialog ───────────────────────────────────────

  Future<bool> _showUploadFailedDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Video Upload Failed'),
            content: const Text(
              'The video could not be uploaded.\n\n'
              'You can still submit the report without the video, '
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

  // ─── Build ──────────────────────────────────────────────────────

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
                    _buildVideoSection(),
                    const SizedBox(height: 20),
                    if (_aiResult != null) _buildAIResult(),
                    const SizedBox(height: 20),
                    _buildIncidentTypeSelector(),
                    const SizedBox(height: 20),
                    _buildDropdowns(),
                    const SizedBox(height: 20),
                    _buildReporterVerification(),
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

  // ─── Widgets ────────────────────────────────────────────────────

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
      final result = _locationResult!;
      // Tapping the location notification opens the accuracy proof view.
      return GestureDetector(
        onTap: () => _openLocationProof(result),
        child: _locationBannerTile(
          icon: Icons.location_on_rounded,
          color: AppColors.success,
          title: 'Location verified (real-time GPS)',
          subtitle: '${result.displayPlace} — accuracy ${result.accuracyText}',
          trailing: const Icon(
            Icons.check_circle_rounded,
            color: AppColors.success,
            size: 20,
          ),
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
                  'Live video • 200km Region 1 coverage',
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
            child: const Icon(Icons.videocam_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Live Video Evidence',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 6),
            Text('*', style: TextStyle(color: AppColors.error, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Point your phone camera at the incident and record. Only 5–10 second videos are accepted.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        // ✅ P3 REVISION: Tall portrait rectangle (9:16) like a phone video,
        // instead of a square box.
        Center(
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.grey100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _videoPath != null ? AppColors.primary : AppColors.grey300,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: _buildVideoPreview(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoPreview() {
    // ✅ P1 REVISION (video-only): after recording, show the RECORDED VIDEO
    // inside a RepaintBoundary so the AI extracts a frame from the video.
    if (_videoPath != null && _videoController != null &&
        _videoController!.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: RepaintBoundary(
              key: _videoFrameKey,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _videoController!.value.size.width,
                  height: _videoController!.value.size.height,
                  child: VideoPlayer(_videoController!),
                ),
              ),
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
                      'AI Analyzing video...',
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
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _toggleVideoPlayback,
                    icon: Icon(
                      _isVideoPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _startRecording,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(14),
                    ),
                    child: const Icon(Icons.replay_rounded, color: Colors.white, size: 24),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // ✅ P4 REVISION: Show the LIVE camera preview (CameraController +
    // CameraPreview) BEFORE and DURING recording so the user can see what
    // they are recording. No static placeholder while recording.
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            // ✅ P2 REVISION: Portrait orientation — invert the camera's
            // aspect ratio so the live preview fills a tall portrait area
            // (like a phone camera held vertically), not square/landscape.
            child: Center(
              child: AspectRatio(
                aspectRatio: 1 / _cameraController!.value.aspectRatio,
                child: CameraPreview(_cameraController!),
              ),
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
        // Recording indicator
        if (_isRecording)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
                  const SizedBox(width: 6),
                  Text(
                    'REC $_recordSeconds/10s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Record / Stop button
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: _isRecording
                ? ElevatedButton(
                    onPressed: _stopRecording,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(18),
                    ),
                    child: const Icon(Icons.stop_rounded, color: Colors.white, size: 28),
                  )
                : ElevatedButton(
                    onPressed: _startRecording,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(18),
                    ),
                    child: const Icon(Icons.videocam_rounded, color: Colors.white, size: 28),
                  ),
          ),
        ),
      ],
    );
    }

    // No camera — show placeholder
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.videocam_off_rounded,
            color: AppColors.primary,
            size: 40,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Camera not available',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          'Live video is required to submit a report',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    );
  }

  // ✅ P1 REVISION: toggle play/pause of the recorded video
  void _toggleVideoPlayback() {
    final vc = _videoController;
    if (vc == null || !vc.value.isInitialized) return;
    if (vc.value.isPlaying) {
      vc.pause();
      setState(() => _isVideoPlaying = false);
    } else {
      vc.play();
      setState(() => _isVideoPlaying = true);
    }
  }

  Widget _buildAIResult() {
    final result = _aiResult!;
    // ✅ P1 REVISION: Hazard reflects the selected severity so it updates
    // automatically when the user changes the severity dropdown.
    final severityColor = _selectedSeverity == 'High'
        ? AppColors.error
        : _selectedSeverity == 'Medium'
        ? Colors.orange
        : AppColors.success;
    final confidenceColor = result.isRejected ? Colors.orange : AppColors.success;

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
              Text(
                'Hazard: ',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: severityColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _selectedSeverity,
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
                'AI Score: ',
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
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.assignment_rounded, color: AppColors.primary, size: 16),
              const SizedBox(width: 6),
              Text(
                'Routed to: ${_departmentFor(_selectedType)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          if (result.isRejected) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Report REJECTED — AI confidence below 80%. '
                      'Record a clearer video.',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.orange,
                      ),
                    ),
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
        // ✅ P1 REVISION: Dropdown menu instead of manual typing
        DropdownButtonFormField<String>(
          value: _selectedType,
          decoration: InputDecoration(
            labelText: 'Select incident type *',
            filled: true,
            fillColor: AppColors.grey100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          items: _incidentTypes
              .map((t) => DropdownMenuItem(value: t, child: Text(t)))
              .toList(),
          onChanged: (val) => setState(() {
            if (val != null) {
              _selectedType = val;
              // ✅ P2 REVISION: user manually changed the incident type —
              // mark it as an override so the submitted report uses the
              // user's choice and routes to the matching department.
              _aiOverriddenByUser = true;
            }
          }),
        ),
      ],
    );
  }

  Widget _buildDropdowns() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Incident Details',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        // Barangay dropdown
        DropdownButtonFormField<String>(
          value: _selectedBarangay,
          decoration: InputDecoration(
            labelText: 'Barangay *',
            filled: true,
            fillColor: AppColors.grey100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          items: _barangays
              .map((b) => DropdownMenuItem(value: b, child: Text(b)))
              .toList(),
          onChanged: (val) => setState(() {
            if (val != null) _selectedBarangay = val;
          }),
        ),
        const SizedBox(height: 12),
        // Severity dropdown
        DropdownButtonFormField<String>(
          value: _selectedSeverity,
          decoration: InputDecoration(
            labelText: 'Severity *',
            filled: true,
            fillColor: AppColors.grey100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          items: _severities
              .map((s) => DropdownMenuItem(value: s, child: Text(s)))
              .toList(),
          onChanged: (val) => setState(() {
            if (val != null) _selectedSeverity = val;
          }),
        ),
      ],
    );
  }

  // ✅ P1 REVISION: Reporter Verification — name + phone from the user's profile
  Widget _buildReporterVerification() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Reporter Verification',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.grey100,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.grey300),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.person_rounded,
                    color: AppColors.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _reporterName.isEmpty ? 'Loading reporter...' : _reporterName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.phone_rounded,
                    color: AppColors.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _reporterPhone.isEmpty
                        ? 'No phone on file'
                        : _reporterPhone,
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
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
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'AI suggested — please review and edit',
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
          maxLength: 500,
          validator: _validateDescription,
          decoration: InputDecoration(
            hintText:
                'Describe what is happening... AI may suggest a description after video analysis.',
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
          builder: (_, value, __) {
            final count = value.text.trim().length;
            Color counterColor = AppColors.textSecondary;

            if (count > 500) {
              counterColor = AppColors.error;
            } else if (count >= 20) {
              counterColor = AppColors.success;
            }

            return Text(
              '$count/500 characters (min 20)',
              style: TextStyle(fontSize: 11, color: counterColor),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSubmitButton() {
    final locationOk = _locationResult != null && _locationResult!.isInDagupan;
    final aiOk = _aiResult != null && !_aiResult!.isRejected;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: (_submitting || !locationOk || !aiOk) ? null : _submitReport,
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
                    color: locationOk && aiOk ? Colors.white : AppColors.grey500,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    !locationOk
                        ? 'Location required to submit'
                        : !aiOk
                            ? 'AI confidence must be 80%+'
                            : 'Submit Report',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: locationOk && aiOk ? Colors.white : AppColors.grey500,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}