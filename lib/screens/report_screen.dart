import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';
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

  // Photo is the quick capture, video is the backup evidence.
  EvidenceStage _evidenceStage = EvidenceStage.photo;
  String? _photoPath;

  // Video backup recorder, 10 seconds max.
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isRecording = false;
  bool _isPreparingRecording = false;
  String? _videoPath;
  int _recordSeconds = 0;

  // Still taken at record time, the AI scores this instead of the video stream.
  String? _videoFramePath;

  // Video player for the recorded backup.
  VideoPlayerController? _videoController;
  bool _isVideoPlaying = false;

  bool _analyzing = false;
  bool _submitting = false;
  bool _fetchingLocation = false;
  String? _uploadStatus;

  // True while the taken photo waits for Okay or Retry, AI has not run yet.
  bool _photoPendingConfirm = false;

  // Photo result is kept so a rejected video cannot erase it.
  AIClassificationResult? _photoResult;

  // Result currently shown and applied, photo or video.
  AIClassificationResult? _aiResult;
  LocationResult? _locationResult;
  String? _locationError;

  // Counts how many times the user was pushed to the video backup.
  int _videoEscalations = 0;

  // True when the photo was below 80%, so the video needs its own score.
  bool _videoNeedsAI = true;

  // True when the newest result is below 80%, so the typed description carries it.
  bool get _scoreRejected => _aiResult?.isRejected ?? false;

  // Submit unlocks once a video exists and no score is still running.
  bool get _videoReviewed => _videoPath != null && !_analyzing;

  String _selectedType = 'Accident';
  String _selectedBarangay = 'Poblacion Oeste';
  String _selectedSeverity = 'High';
  DateTime? _lastSubmitTime;

  // True when the user manually changed the incident type after AI analysis.
  bool _aiOverriddenByUser = false;

  String _reporterName = '';
  String _reporterPhone = '';

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

  // Maps an incident type to its assigned department.
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

  // Pulls reporter name and phone from the logged-in user's profile.
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

  // ─── Quick capture (photo) ───────────────────────────────────────────────

  // Shutter inside the photo box takes the shot, AI waits for Okay.
  Future<void> _takePhoto() async {
    final camera = _cameraController;
    if (camera == null || !camera.value.isInitialized) {
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
      final shot = await camera.takePicture();
      if (!mounted) return;
      setState(() {
        _photoPath = shot.path;
        _photoPendingConfirm = true;
        _aiResult = null;
        _photoResult = null;
      });
    } catch (e) {
      debugPrint('Photo capture error: $e');
      Get.snackbar(
        'Camera Error',
        'Could not take the photo. Please try again.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
    }
  }

  // Retry drops the shot and returns to the live preview.
  void _retryPhoto() {
    setState(() {
      _photoPath = null;
      _photoPendingConfirm = false;
      _aiResult = null;
      _photoResult = null;
    });
  }

  // Okay is the only thing that starts the AI analysis.
  Future<void> _confirmPhoto() async {
    if (_photoPath == null) return;
    setState(() => _photoPendingConfirm = false);
    await _analyzeWithAI(_photoPath!, EvidenceStage.photo);
  }

  // ─── Video backup ────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;
      final back = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      // Medium preset keeps the live preview smooth on a real phone.
      _cameraController = CameraController(back, ResolutionPreset.medium);
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording || _isPreparingRecording) return;
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
    setState(() {
      _isPreparingRecording = true;
      if (_videoNeedsAI) _aiResult = null;
      _videoPath = null;
      _isVideoPlaying = false;
    });
    _videoFramePath = null;
    try {
      // Still taken now, the camera cannot hand over a video frame later.
      String? framePath;
      if (_videoNeedsAI) {
        try {
          final shot = await _cameraController!.takePicture();
          framePath = shot.path;
          if (mounted) setState(() => _videoFramePath = framePath);
        } catch (e) {
          debugPrint('Video frame error: $e');
        }
      }
      await _cameraController!.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _isPreparingRecording = false;
        _isRecording = true;
        _recordSeconds = 0;
      });
      _startTimer();
    } catch (e) {
      debugPrint('Start recording error: $e');
      if (mounted) {
        setState(() => _isPreparingRecording = false);
      }
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
        // Show the scoring state straight away when a score is coming.
        _analyzing = _videoNeedsAI;
      });
      await _setupVideoController();
      // A photo below 80% needs the video scored as well.
      if (_videoNeedsAI) await _analyzeVideo();
    } catch (e) {
      debugPrint('Stop recording error: $e');
      setState(() => _isRecording = false);
    }
  }

  // Loads the recorded video so it can be replayed or recorded again.
  Future<void> _setupVideoController() async {
    if (_videoPath == null) return;
    try {
      _videoController?.dispose();
      _videoController = VideoPlayerController.file(File(_videoPath!));
      await _videoController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Video controller error: $e');
    }
  }

  // Scores the video backup, using the still taken when recording started.
  Future<void> _analyzeVideo() async {
    var framePath = _videoFramePath;
    // A missing still is retaken so the video is never left unscored.
    if (framePath == null) {
      try {
        final shot = await _cameraController!.takePicture();
        framePath = shot.path;
        _videoFramePath = framePath;
      } catch (e) {
        debugPrint('Video frame retry error: $e');
        if (mounted) setState(() => _analyzing = false);
        return;
      }
    }
    await _analyzeWithAI(framePath, EvidenceStage.video);
  }

  // ─── Location ────────────────────────────────────────────────────────────

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

  // ─── Validators ──────────────────────────────────────────────────────────

  String? _validateEvidence() {
    // Both files are submitted, so both must exist.
    if (_photoPath == null) return 'A photo is required to submit a report';
    if (_videoPath == null) return 'A video backup is required to submit';
    return null;
  }

  String? _validateDescription(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please describe what is happening';
    }
    if (value.trim().length < 20) {
      return 'Description is too short, please provide more detail';
    }
    if (value.trim().length > 500) {
      return 'Description is too long, maximum 500 characters';
    }
    if (RegExp(r'[<>{}\[\]\\]').hasMatch(value)) {
      return 'Description contains invalid characters';
    }
    return null;
  }

  // ─── AI analysis and the escalation loop ─────────────────────────────────

  // Builds the starting description from the accepted AI facts only.
  String _suggestedDescription(AIClassificationResult result) {
    return '${result.category} reported in $_selectedBarangay. '
        'Severity assessed as ${result.severityLabel}.';
  }

  // Scores one evidence frame. A rejected video must not erase the photo facts.
  Future<void> _analyzeWithAI(String framePath, EvidenceStage stage) async {
    setState(() => _analyzing = true);

    try {
      final result = await EmergencyAIService.instance.classifyImage(
        framePath,
        stage: stage,
      );

      if (!mounted) return;

      // A video still below 80% keeps the photo's facts on screen.
      final applyFacts = stage == EvidenceStage.photo || !result.isRejected;

      setState(() {
        _aiResult = result;
        if (stage == EvidenceStage.photo) _photoResult = result;
        _analyzing = false;
        // The accepted type pre-fills the dropdown, the user can still change it.
        if (applyFacts && _incidentTypes.contains(result.category)) {
          _selectedType = result.category;
        }
        // Severity box mirrors the AI band, so it is filled, never picked.
        if (applyFacts) {
          _selectedSeverity = result.severityLabel;
          _aiOverriddenByUser = false;
        }
        // Only real incident text is pre-filled, never the AI status sentence.
        if (!result.isRejected) {
          _descriptionController.text = _suggestedDescription(result);
        }
      });

      // The photo always moves on to the video backup, accepted or not.
      if (stage == EvidenceStage.photo) {
        _escalateToVideo(keepPhotoInfo: !result.isRejected);
      }
      // A rejected video stays put, the replay button starts a new recording.
    } catch (e) {
      debugPrint('TFLite error: $e');
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        if (stage == EvidenceStage.photo) {
          _aiResult = null;
          _photoResult = null;
          // Bring the Retry and Okay buttons back so the photo can be redone.
          _photoPendingConfirm = true;
        }
      });
    }
  }

  // The video backup runs after the photo, accepted or not.
  void _escalateToVideo({bool keepPhotoInfo = false}) {
    // Only a rejected photo counts as an escalation.
    if (!keepPhotoInfo) _videoEscalations++;
    setState(() {
      _evidenceStage = EvidenceStage.video;
      // An accepted photo needs no second score, the video is upload only.
      _videoNeedsAI = !keepPhotoInfo;
    });
  }

  // ─── Submit ──────────────────────────────────────────────────────────────

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
    // 0. Rate limiting, 30 second cooldown.
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

    // 1. Validate the evidence for the current stage.
    final evidenceError = _validateEvidence();
    if (evidenceError != null) {
      Get.snackbar(
        'Evidence Required',
        evidenceError,
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
      );
      return;
    }

    // 2. Check file size, max 20MB, for every captured file.
    final evidencePaths = <String>[
      if (_photoPath != null) _photoPath!,
      if (_videoPath != null) _videoPath!,
    ];
    for (final path in evidencePaths) {
      final sizeInMB = File(path).lengthSync() / (1024 * 1024);
      if (sizeInMB > 20) {
        Get.snackbar(
          'File Too Large',
          'Please use a file smaller than 20MB.',
          backgroundColor: AppColors.error,
          colorText: Colors.white,
          margin: const EdgeInsets.all(16),
        );
        return;
      }
    }

    // 3. Validate location.
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

    // 4. AI gate. A photo below 80% must have been escalated to video first.
    if (_aiResult == null) {
      Get.snackbar(
        'AI Analysis Required',
        'Please capture a photo so the AI can analyse the incident.',
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      );
      return;
    }
    // 5. Sanitize description before form validation.
    final sanitizedDesc = _descriptionController.text.trim().replaceAll(
      RegExp(r'[<>{}\[\]\\]'),
      '',
    );
    _descriptionController.text = sanitizedDesc;

    // 6. Validate form fields.
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // 7. Confirm submission.
    final confirm = await _showSubmitConfirmationDialog();
    if (!confirm) return;

    // 8. Set rate limit timestamp.
    _lastSubmitTime = DateTime.now();

    setState(() {
      _submitting = true;
      _uploadStatus = 'Uploading evidence...';
    });

    try {
      // Snapshot both evidence paths so the photo survives a video escalation.
      final photoPath = _photoPath;
      final videoPath = _videoPath;

      // Step 1: Upload every piece of evidence the user actually captured.
      String? photoUrl;
      String? videoUrl;

      if (photoPath != null) {
        setState(() => _uploadStatus = 'Uploading photo...');
        photoUrl = await CloudinaryService.instance.uploadImage(photoPath);
        if (photoUrl == null) {
          setState(() {
            _uploadStatus = null;
            _submitting = false;
          });
          Get.snackbar(
            'Photo Upload Failed',
            'The photo could not be uploaded. Please try submitting again.',
            backgroundColor: AppColors.error,
            colorText: Colors.white,
            margin: const EdgeInsets.all(16),
          );
          return;
        }
      }

      if (videoPath != null) {
        setState(() => _uploadStatus = 'Uploading video...');
        videoUrl = await CloudinaryService.instance.uploadVideo(videoPath);
        if (videoUrl == null) {
          setState(() {
            _uploadStatus = null;
            _submitting = false;
          });
          Get.snackbar(
            'Video Upload Failed',
            'The video could not be uploaded. Please try submitting again.',
            backgroundColor: AppColors.error,
            colorText: Colors.white,
            margin: const EdgeInsets.all(16),
          );
          return;
        }
      }

      if (photoUrl != null || videoUrl != null) {
        setState(() => _uploadStatus = 'Submitting report...');
      }

      // Step 2: Submit. userId is not sent from the client, set server-side.
      // Use the type and department actually submitted, not a stale AI value.
      final submittedType = _selectedType;
      final submittedDepartment = _departmentFor(submittedType);
      final submittedCategory = _aiOverriddenByUser
          ? submittedType
          : (_aiResult?.category ?? submittedType);

      // Severity is read-only and mirrors the AI band, which is LOW in the fallback.
      final severity = _aiResult?.severityLabel ?? _selectedSeverity;

      await AuthService.instance.submitReport({
        'type': submittedType,
        'description': sanitizedDesc,
        'aiCategory': submittedCategory,
        'aiConfidence': _aiResult?.confidence,
        'aiOverriddenByUser': _aiOverriddenByUser,
        // A rejected photo means the typed description is the user's own.
        'manuallyDescribed': _scoreRejected,
        'evidenceStage': _evidenceStage == EvidenceStage.photo
            ? 'photo'
            : 'video',
        'videoEscalations': _videoEscalations,
        'videoUrl': videoUrl,
        'photoUrl': photoUrl,
        // Photo evidence must reach the document, not just the upload call.
        'imageUrl': photoUrl,
        'imageUploaded': photoUrl != null,
        // Reporter identity stays top level so the dashboard can read it.
        'reporterName': _reporterName,
        'reporterPhone': _reporterPhone,
        // Location map holds GPS only, nothing else goes inside it.
        'location': _locationResult!.toMap(),
        'status': 'pending',
        'assignedDepartment': submittedDepartment,
        'barangay': _selectedBarangay,
        'severity': severity,
        'createdAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _submitting = false;
        _uploadStatus = null;
      });

      Get.back();
      Get.snackbar(
        'Report Submitted',
        'Your report has been sent to $submittedDepartment',
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

  // ─── Build ───────────────────────────────────────────────────────────────

  // Detail sections appear once the photo has a result, accepted or not.
  bool get _showDetailSections => _aiResult != null;

  // Incident details follow the same rule, severity stays read-only.
  bool get _showIncidentDetailsSection => _showDetailSections;

  // Description follows the same rule, the fallback only rewrites its label.
  bool get _showDescriptionSection => _showDetailSections;

  // Reporter info appears once a photo has been taken, it stays through the fallback.
  bool get _showReporterSection => _photoPath != null;

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
                    _buildEvidenceSection(),
                    if (!_isPreparingRecording && !_isRecording) ...[
                      if (_aiResult != null) ...[
                        const SizedBox(height: 20),
                        _buildAIResult(),
                      ],
                      if (_showDetailSections) ...[
                        const SizedBox(height: 20),
                        _buildIncidentTypeSelector(),
                      ],
                      if (_showIncidentDetailsSection) ...[
                        const SizedBox(height: 20),
                        _buildDropdowns(),
                      ],
                      if (_showReporterSection) ...[
                        const SizedBox(height: 20),
                        _buildReporterVerification(),
                      ],
                      if (_showDescriptionSection) ...[
                        const SizedBox(height: 20),
                        _buildDescriptionField(),
                      ],
                      if (_videoReviewed) ...[
                        const SizedBox(height: 32),
                        _buildSubmitButton(),
                      ],
                    ],
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

  // ─── Widgets ─────────────────────────────────────────────────────────────

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
          subtitle: '${result.displayPlace} - accuracy ${result.accuracyText}',
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
                  'Quick photo capture, video backup if needed',
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
            child: const Icon(Icons.camera_alt_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  // Photo stage shows the quick capture, video stage shows the recorder.
  Widget _buildEvidenceSection() {
    if (_evidenceStage == EvidenceStage.photo) {
      return _buildPhotoSection();
    }
    return _buildVideoSection();
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
        Center(
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.grey100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _photoPath != null
                      ? AppColors.primary
                      : AppColors.grey300,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: _buildPhotoPreview(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Three states: live camera, taken photo waiting for Okay, or analyzed.
  Widget _buildPhotoPreview() {
    // Taken photo comes first, with Retry and Okay, AI has not run yet.
    if (_photoPath != null && _photoPendingConfirm) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(_photoPath!), fit: BoxFit.cover),
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _retryPhoto,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.grey700,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  icon: const Icon(Icons.replay_rounded, color: Colors.white),
                  label: const Text(
                    'Retry',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _confirmPhoto,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  icon: const Icon(Icons.check_rounded, color: Colors.white),
                  label: const Text(
                    'Okay',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Analyzed photo, shown with its AI overlay.
    if (_photoPath != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(_photoPath!), fit: BoxFit.cover),
          if (_analyzing)
            Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'AI Analyzing photo...',
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
        ],
      );
    }

    // Live camera preview with the shutter, same as the video box.
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 1 / _cameraController!.value.aspectRatio,
              child: CameraPreview(_cameraController!),
            ),
          ),
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                onPressed: _takePhoto,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(6),
                ),
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: const Icon(
                    Icons.camera_alt_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 16),
          Text(
            'Starting camera...',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // Subtitle follows the flow: guidance, then the video score.
  String _videoSubtitle() {
    final photoAccepted = _photoResult != null && !_photoResult!.isRejected;

    // Video not recorded yet, so show the guidance for this stage.
    if (_videoPath == null) {
      return photoAccepted
          ? 'Photo accepted. Record a 5 to 10 second video as backup evidence.'
          : 'The photo score is below 80% and not accepted. Record a 5 to 10 second video as backup evidence for further review.';
    }

    // Score is still being read, so do not guess the outcome.
    if (_analyzing) return 'Scoring the video backup...';

    // An accepted photo needs no second score, the video is upload only.
    if (!_videoNeedsAI) {
      return 'Video recorded. Both the photo and the video evidence will be submitted.';
    }

    final videoResult =
        _aiResult?.stage == EvidenceStage.video ? _aiResult : null;
    if (videoResult == null) {
      return 'Video not scored yet. Record the video again to get a score.';
    }
    if (!videoResult.isRejected) {
      return 'Video accepted at ${videoResult.confidenceLabel}. '
          'Both the photo and the video evidence will be submitted.';
    }
    return 'Video is below 80% and not accepted. '
        'Record another video, or keep this video, fill the information below and describe what is happening before submitting.';
  }

  Widget _buildVideoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Video Backup Evidence',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 6),
            Text('*', style: TextStyle(color: AppColors.error, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _videoSubtitle(),
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Center(
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.grey100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _videoPath != null
                      ? AppColors.primary
                      : AppColors.grey300,
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
    // After recording, show the recorded video inside the box.
    if (_videoPath != null &&
        _videoController != null &&
        _videoController!.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoController!.value.size.width,
                height: _videoController!.value.size.height,
                child: VideoPlayer(_videoController!),
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
                    child: const Icon(
                      Icons.replay_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Live camera preview before and during recording.
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
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
          if (_isRecording)
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.fiber_manual_record,
                      color: Colors.white,
                      size: 12,
                    ),
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
                      child: const Icon(
                        Icons.stop_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    )
                  : ElevatedButton(
                      onPressed: _startRecording,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(18),
                      ),
                      child: const Icon(
                        Icons.videocam_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
            ),
          ),
        ],
      );
    }

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
          'A video backup is required to submit this report',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    );
  }

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

    // Mobile severity colours: Low grey, Medium orange, High red.
    final bandColor = switch (result.band) {
      SeverityBand.high => AppColors.error,
      SeverityBand.medium => Colors.orange,
      SeverityBand.low => AppColors.grey500,
    };

    final severityText = result.severityLabel.toUpperCase();

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
                'Severity: ',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: bandColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  severityText,
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
                    color: bandColor,
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
                  color: bandColor,
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
          // Routed to follows the incident type, so it changes with the dropdown.
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.assignment_rounded,
                color: AppColors.primary,
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Routed to: ${_departmentFor(_selectedType)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (result.isRejected) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      result.stage == EvidenceStage.photo
                          ? 'Photo below 80%. A video backup is required.'
                          : 'Video backup still below 80%. Describe the incident below.',
                      style: const TextStyle(
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
              // User changed the type, so mark it as an override.
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
        // Severity is read-only in every state, it mirrors the AI band.
        _buildReadOnlySeverity(),
      ],
    );
  }

  // Read-only severity box, it always shows the AI band.
  Widget _buildReadOnlySeverity() {
    final label = _aiResult?.severityLabel ?? _selectedSeverity;
    final color = switch (_aiResult?.band) {
      SeverityBand.high => AppColors.error,
      SeverityBand.medium => Colors.orange,
      SeverityBand.low => AppColors.grey500,
      null => AppColors.grey500,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.grey100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.grey300),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Severity (set by AI)',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
                    _reporterName.isEmpty
                        ? 'Loading reporter...'
                        : _reporterName,
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
                color: _scoreRejected
                    ? AppColors.error.withValues(alpha: 0.1)
                    : AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _scoreRejected
                    ? 'Required, describe it yourself'
                    : 'AI suggested, please review and edit',
                style: TextStyle(
                  color: _scoreRejected
                      ? AppColors.error
                      : AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (_scoreRejected) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.error.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.edit_note_rounded,
                  color: AppColors.error,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The photo scored below 80%. Please describe the incident '
                    'in your own words so responders can still act on it. '
                    'This report is marked LOW severity.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextFormField(
          controller: _descriptionController,
          maxLines: 4,
          maxLength: 500,
          validator: _validateDescription,
          decoration: InputDecoration(
            hintText:
                'Describe what is happening... AI may suggest a description after analysis.',
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
    // A video still below 80% submits with the typed description.
    final aiOk = _aiResult != null;
    final canSubmit = locationOk && aiOk && !_submitting;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: canSubmit ? _submitReport : null,
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
                    color: canSubmit ? Colors.white : AppColors.grey500,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    !locationOk
                        ? 'Location required to submit'
                        : _aiResult == null
                        ? 'Capture a photo first'
                        : _scoreRejected
                        ? 'Submit with my description'
                        : 'Submit Report',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: canSubmit ? Colors.white : AppColors.grey500,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
