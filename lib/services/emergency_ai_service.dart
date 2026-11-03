import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// Mobile severity band. Web adds Critical and repeat reports later.
enum SeverityBand { low, medium, high }

// Which evidence the user is on: photo first, video only as backup.
enum EvidenceStage { photo, video }

// Structured result with confidence, severity band and escalation stage.
class AIClassificationResult {
  final String category;
  final double confidence;

  // Stage this result came from, so the screen knows what to ask for next.
  final EvidenceStage stage;

  // 80% is the lowest score that can be accepted at all.
  static const double acceptThreshold = 0.80;

  // 90% and above is treated as high.
  static const double highThreshold = 0.90;

  const AIClassificationResult({
    required this.category,
    required this.confidence,
    this.stage = EvidenceStage.photo,
  });

  // Percentage as a whole number, used in every message.
  int get percent => (confidence * 100).round();

  // Below 80% is rejected and needs a video backup.
  bool get isRejected => confidence < acceptThreshold;

  // 80 to 89 percent.
  bool get isMedium =>
      confidence >= acceptThreshold && confidence < highThreshold;

  // 90 percent and above.
  bool get isHigh => confidence >= highThreshold;

  // Mobile rule: below 80 LOW, 80-89 MEDIUM, 90-100 HIGH.
  SeverityBand get band {
    if (isHigh) return SeverityBand.high;
    if (isMedium) return SeverityBand.medium;
    return SeverityBand.low;
  }

  // Severity word stored with the report.
  String get severityLabel {
    switch (band) {
      case SeverityBand.high:
        return 'High';
      case SeverityBand.medium:
        return 'Medium';
      case SeverityBand.low:
        return 'Low';
    }
  }

  // Short label for the confidence chip.
  String get confidenceLabel => '$percent%';

  // AI auto-routes to the correct response department.
  String get department {
    switch (category) {
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

  // Message shown under the AI card, changes with the stage.
  String get description {
    if (isRejected) {
      if (stage == EvidenceStage.photo) {
        return 'AI confidence is only $confidenceLabel, below the 80% '
            'acceptance threshold. A video backup is now required.';
      }
      return 'AI confidence is still only $confidenceLabel after the video '
          'backup. This report is marked LOW severity, so please describe the '
          'incident in your own words before submitting.';
    }
    return 'AI detected: $category ($confidenceLabel). '
        'Routed to: $department. Please verify before submitting.';
  }

  // Copy of this result moved to the video stage.
  AIClassificationResult asVideoStage() => AIClassificationResult(
    category: category,
    confidence: confidence,
    stage: EvidenceStage.video,
  );
}

class EmergencyAIService {
  EmergencyAIService._();
  static final instance = EmergencyAIService._();

  Interpreter? _interpreter;
  List<String> _labels = [];

  // Only 5 categories, Others removed.
  static const List<String> validCategories = [
    'Fire',
    'Flood',
    'Medical Emergency',
    'Accident',
    'Crime',
  ];

  Future<void> init() async {
    if (_interpreter != null) return;

    final labelsRaw = await rootBundle.loadString('assets/models/labels.txt');
    _labels = labelsRaw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final options = InterpreterOptions()..threads = 2;

    _interpreter = await Interpreter.fromAsset(
      'assets/models/emergency_model.tflite',
      options: options,
    );
  }

  // Returns a structured result instead of a raw map.
  Future<AIClassificationResult> classifyImage(
    String path, {
    EvidenceStage stage = EvidenceStage.photo,
  }) async {
    await init();

    final interpreter = _interpreter!;
    final inputTensor = interpreter.getInputTensor(0);
    final inputShape = inputTensor.shape;
    final inputType = inputTensor.type;

    final int height = inputShape[1];
    final int width = inputShape[2];

    final Uint8List bytes = await File(path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return AIClassificationResult(
        category: 'Flood',
        confidence: 0.0,
        stage: stage,
      );
    }

    final resized = img.copyResize(decoded, width: width, height: height);

    dynamic input;

    if (inputType == TensorType.float32) {
      input = List.generate(1, (_) {
        return List.generate(height, (y) {
          return List.generate(width, (x) {
            final pixel = resized.getPixel(x, y);
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          });
        });
      });
    } else {
      input = List.generate(1, (_) {
        return List.generate(height, (y) {
          return List.generate(width, (x) {
            final pixel = resized.getPixel(x, y);
            return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
          });
        });
      });
    }

    final outputTensor = interpreter.getOutputTensor(0);
    final int numClasses = outputTensor.shape.last;
    final output = List.generate(1, (_) => List.filled(numClasses, 0.0));

    interpreter.run(input, output);

    final probs = output[0];

    int bestIdx = 0;
    double bestVal = probs[0];
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > bestVal) {
        bestVal = probs[i];
        bestIdx = i;
      }
    }

    String rawLabel = bestIdx < _labels.length ? _labels[bestIdx] : 'Flood';

    // Normalize an unknown model label to one of the 5 categories.
    if (!validCategories.contains(rawLabel)) {
      rawLabel = _mapUnknownLabel(rawLabel);
    }

    return AIClassificationResult(
      category: rawLabel,
      confidence: bestVal,
      stage: stage,
    );
  }

  // Maps unknown model labels to one of the 5 categories.
  String _mapUnknownLabel(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('fire') || lower.contains('burn')) return 'Fire';
    if (lower.contains('flood') || lower.contains('water')) return 'Flood';
    if (lower.contains('accident') || lower.contains('crash')) return 'Accident';
    if (lower.contains('crime') ||
        lower.contains('rob') ||
        lower.contains('theft')) {
      return 'Crime';
    }
    if (lower.contains('medical') ||
        lower.contains('ambulance') ||
        lower.contains('heart') ||
        lower.contains('drown')) {
      return 'Medical Emergency';
    }
    return 'Flood';
  }

  // Legacy method kept for backward compat, delegates to classifyImage.
  Future<Map<String, dynamic>> classifyImageFile(String path) async {
    final result = await classifyImage(path);
    return {'label': result.category, 'confidence': result.confidence};
  }
}
