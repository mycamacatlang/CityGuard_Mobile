import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

//  Structured result with confidence — enables override UI in report_screen
class AIClassificationResult {
  final String category;
  final double confidence;

  // Flags low-confidence results so the UI can force manual override
  bool get requiresManualOverride => confidence < 0.60;

  // Human-readable confidence label
  String get confidenceLabel => '${(confidence * 100).toStringAsFixed(0)}%';

  // Severity derived from category
  String get severity {
    switch (category) {
      case 'Fire':
      case 'Flood':
      case 'Accident':
      case 'Medical Emergency':
      case 'Crime':
        return 'High';
      case 'Others':
        return 'Low';
      default:
        return 'Medium';
    }
  }

  // Description shown to user
  String get description {
    if (requiresManualOverride) {
      return 'AI is not confident ($confidenceLabel). '
          'Please select the correct incident type manually and describe what happened.';
    }
    return 'AI detected: $category ($confidenceLabel). '
        'Please verify the incident type before submitting.';
  }

  // Legacy string format kept for backward compat with _buildAIResult()
  String get legacyResultString =>
      'Type: $category\nDescription: $description\nSeverity: $severity';

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

  // Valid incident types that map to the report screen's selector
  static const List<String> validCategories = [
    'Accident',
    'Fire',
    'Flood',
    'Crime',
    'Medical Emergency',
    'Others',
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
      return const AIClassificationResult(category: 'Others', confidence: 0.0);
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

    String rawLabel = bestIdx < _labels.length ? _labels[bestIdx] : 'Others';

    //  MITIGATION: Normalize label to a known valid category
    if (!validCategories.contains(rawLabel)) rawLabel = 'Others';

    //  MITIGATION: Force 'Others' when confidence is too low
    if (bestVal < 0.60) rawLabel = 'Others';

    return AIClassificationResult(category: rawLabel, confidence: bestVal);
  }

  // Legacy method kept for backward compat — delegates to classifyImage
  Future<Map<String, dynamic>> classifyImageFile(String path) async {
    final result = await classifyImage(path);
    return {'label': result.category, 'confidence': result.confidence};
  }
}
