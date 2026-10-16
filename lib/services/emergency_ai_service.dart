import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

//  Structured result with confidence — enables override UI in report_screen
class AIClassificationResult {
  final String category;
  final double confidence;

  // ✅ P1 REVISION: AI confidence threshold raised to 80% (0.80)
  // Reports below 80% are REJECTED (not accepted with manual override).
  static const double acceptThreshold = 0.80;

  // ✅ P1 REVISION: true when confidence is below 80% → report is rejected
  bool get isRejected => confidence < acceptThreshold;

  // Human-readable confidence label
  String get confidenceLabel => '${(confidence * 100).toStringAsFixed(0)}%';

  // ✅ P1 REVISION: AI auto-routes to the correct response department
  String get department {
    switch (category) {
      case 'Fire':
        return 'BFP';
      case 'Flood':
        return 'CDRRMO/MDRRMOA';
      case 'Accident':
      case 'Medical Emergency':
        return 'Medical Emergency Team and Responders';
      case 'Crime':
        return 'PNP';
      default:
        return 'CDRRMO/MDRRMOA';
    }
  }

  // Severity derived from category
  String get severity {
    switch (category) {
      case 'Fire':
      case 'Flood':
      case 'Accident':
      case 'Medical':
      case 'Crime':
      case 'Drowning':
      case 'Earthquake':
      case 'Typhoon':
        return 'High';
      default:
        return 'Medium';
    }
  }

  // Description shown to user
  String get description {
    if (isRejected) {
      return 'AI confidence is only $confidenceLabel (below the 80% '
          'acceptance threshold). This report cannot be submitted. '
          'Please record a clearer video of the incident.';
    }
    return 'AI detected: $category ($confidenceLabel). '
        'Routed to: $department. Please verify before submitting.';
  }

  const AIClassificationResult({
    required this.category,
    required this.confidence,
  });
}

class EmergencyAIService {
  EmergencyAIService._();
  static final instance = EmergencyAIService._();

  Interpreter? _interpreter;
  List<String> _labels = [];

  // ✅ P1 REVISION: Only 5 categories (FINAL) — Others removed
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

  // Returns structured AIClassificationResult instead of raw map
  Future<AIClassificationResult> classifyImage(String path) async {
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
      return const AIClassificationResult(category: 'Flood', confidence: 0.0);
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

    // ✅ P1 REVISION: Normalize label to a known valid category.
    // If the model returns an unknown label, map it to a specific category
    // (never "Others").
    if (!validCategories.contains(rawLabel)) {
      rawLabel = _mapUnknownLabel(rawLabel);
    }

    return AIClassificationResult(category: rawLabel, confidence: bestVal);
  }

  // ✅ P1 REVISION: Map unknown model labels to one of the 5 categories.
  String _mapUnknownLabel(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('fire') || lower.contains('burn')) return 'Fire';
    if (lower.contains('flood') || lower.contains('water')) return 'Flood';
    if (lower.contains('accident') || lower.contains('crash')) return 'Accident';
    if (lower.contains('crime') || lower.contains('rob') || lower.contains('theft')) {
      return 'Crime';
    }
    if (lower.contains('medical') || lower.contains('ambulance') || lower.contains('heart') || lower.contains('drown')) {
      return 'Medical Emergency';
    }
    return 'Flood'; // default specific category — never "Others"
  }

  // Legacy method kept for backward compat — delegates to classifyImage
  Future<Map<String, dynamic>> classifyImageFile(String path) async {
    final result = await classifyImage(path);
    return {'label': result.category, 'confidence': result.confidence};
  }
}