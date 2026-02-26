import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class EmergencyAIService {
  EmergencyAIService._();
  static final instance = EmergencyAIService._();

  Interpreter? _interpreter;
  List<String> _labels = [];

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

  Future<Map<String, dynamic>> classifyImageFile(String path) async {
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
      return {'label': 'Others', 'confidence': 0.0};
    }

    final resized = img.copyResize(decoded, width: width, height: height);

    dynamic input;

    if (inputType == TensorType.float32) {
      input = List.generate(1, (_) {
        return List.generate(height, (y) {
          return List.generate(width, (x) {
            final pixel = resized.getPixel(x, y);
            final r = pixel.r / 255.0;
            final g = pixel.g / 255.0;
            final b = pixel.b / 255.0;
            return [r, g, b];
          });
        });
      });
    } else {
      input = List.generate(1, (_) {
        return List.generate(height, (y) {
          return List.generate(width, (x) {
            final pixel = resized.getPixel(x, y);
            final r = pixel.r.toInt();
            final g = pixel.g.toInt();
            final b = pixel.b.toInt();
            return [r, g, b];
          });
        });
      });
    }

    final outputTensor = interpreter.getOutputTensor(0);
    final outShape = outputTensor.shape;
    final int numClasses = outShape.last;

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

    final bestLabel = bestIdx < _labels.length ? _labels[bestIdx] : 'Others';

    return {'label': bestLabel, 'confidence': bestVal};
  }
}
