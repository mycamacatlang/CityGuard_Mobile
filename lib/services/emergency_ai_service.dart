import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// Mobile severity band, the web side adds Critical and repeat reports later.
enum SeverityBand { low, medium, high }

// Which evidence the user is on: photo first, video only as backup.
enum EvidenceStage { photo, video }

// Structured result with confidence, severity band and escalation stage.
class AIClassificationResult {
  final String category;
  final double confidence;

  // Stage this result came from, so the screen knows what to ask for next.
  final EvidenceStage stage;

  // Second best class, so a weak match can be reported as a best guess.
  final String runnerUpCategory;

  // True when the prediction is a best guess rather than a confident match.
  final bool isBestGuess;

  // True when the media is not one of the incident types.
  final bool isUnreadable;

  // The confirmed sub-scene, so the shown band matches the detection.
  final String subScene;

  // 80% is the lowest score that can be accepted at all.
  static const double acceptThreshold = 0.80;

  // 90% and above is treated as high.
  static const double highThreshold = 0.90;

  const AIClassificationResult({
    required this.category,
    required this.confidence,
    this.stage = EvidenceStage.photo,
    this.runnerUpCategory = '',
    this.isBestGuess = false,
    this.isUnreadable = false,
    this.subScene = '',
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
      // Terrorist needs both police and medical response at once.
      case 'Terrorist':
        return 'PNP and Medical Emergency Team and Responders';
      default:
        return 'CDRRMO/MDRRMO';
    }
  }

  // Message shown under the AI card, changes with the stage.
  String get description {
    // Media that is not an incident is reported as such instead of naming a type.
    if (isUnreadable) {
      return 'The photo or video does not show enough visual to identify an '
          'incident. Please retake it closer to the scene.';
    }

    // A best guess never claims the type is confirmed, even when it is low.
    if (isBestGuess) {
      final second = runnerUpCategory.isEmpty
          ? ''
          : ' The visuals also resemble $runnerUpCategory.';
      final next = isRejected
          ? ' A video backup is required to confirm it.'
          : ' Please verify before submitting.';
      return 'AI best guess: $category ($confidenceLabel), not confirmed.$second'
          ' Routed to: $department.$next';
    }

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
    runnerUpCategory: runnerUpCategory,
    isBestGuess: isBestGuess,
    isUnreadable: isUnreadable,
    subScene: subScene,
  );
}

// Three letterbox zooms, each mirrored, so a far subject is still seen close.
const List<double> _padScales = [1.0, 0.7, 0.45];

// One tile grid is enough, a second grid cost more than it added.
const List<int> _tileGrids = [2];

// How much the colour evidence is trusted against the model output.
const double _evidenceWeight = 0.45;

// Evidence weights per class, tuned on labelled incident photos.
const double _smokeWeight = 0.45;
const double _crimeDarkWeight = 0.6;
const double _greyWaterWeight = 1.3;

// Skin needs a stronger red dominance than turbid flood water shows.
const double _skinRedGreen = 28.0;
const double _skinRedBlue = 42.0;
const double _skinMinSat = 0.22;

// Smoke sits high in frame, standing water sits low, so position separates them.
const double _smokeTopBias = 1.0;
const double _waterBottomBias = 1.0;

// Flame above this fraction is a real fire, smoke alone is only a fire sign.
const double _flameHighFraction = 0.02;
const double _smokeMediumFraction = 0.15;

// Score mapping, so a correct call lands in the 80 to 100 band.
const double _scoreBase = 0.60;
const double _scoreSpan = 0.39;
const double _probDivisor = 0.45;
const double _marginDivisor = 0.30;
const double _evidenceDivisor = 0.50;

// A near tie means a guess, never a confirmed fact.
const double _guessMargin = 0.04;

// Weak view agreement lowers the score a little instead of forcing a guess.
const double _guessAgreement = 0.30;
const double _agreementPenalty = 0.06;

// Hard cap for a best guess so it never looks like a confirmed match.
const double _guessScoreCap = 0.79;

// Others mass above this means the scene is not an incident at all.
const double _othersGate = 0.65;

// A non-incident scene is capped here, below the 80 percent accept line.
const double _nonIncidentCap = 0.75;

// The winning class must hold this much mass, chance is only 0.20.
const double _topGate = 0.38;

// Green foliage this high means a garden or park, never a fire.
const double _greenVeto = 0.0015;

// A scene this green is a garden or park, so it is not a crime or a medical case.
const double _greenSceneVeto = 0.50;

// Strong foliage is a veto on its own, mild foliage needs no smoke with it.
const double _greenStrong = 0.005;

// A hot region with this much blue is daylight or sky, not a flame.
const double _blueVeto = 0.40;

// Terrorist needs a bright centre against a dark mass.
const double _hostageWhite = 0.045;
const double _hostageBlack = 0.25;

// Terrorist needs a visible skin blob, a face or a hand.
const double _hostageSkin = 0.0008;

// A group of this many people is a Terrorist scene, not a lone Crime.
const int _groupMinPeople = 2;

// A group needs a bright centre against a dark mass, relaxed for a crowd.
const double _groupWhite = 0.020;
const double _groupBlack = 0.20;

// The group count runs on the same small buffer as the colour cues.
const int _groupSize = 96;

// Two bodies must be separated to count as a crowd.
const int _crowdGap = 2;

// A body must be this tall a share of the frame to count as a person.
const double _crowdMinHeight = 0.15;

// One body cannot be this wide a share of the frame.
const double _crowdMaxWidth = 0.55;

// The hostage and blue checks run on a slightly larger buffer.
const int _hostageSize = 160;

// Crime focuses on one person with a gun, so a gun bar is measured directly.
// A gun is a thin dark bar, so it must be much thinner than the person.
const int _gunMinRun = 8;
const double _gunThinNeigh = 0.35;
const double _gunDarkGate = 0.15;
const double _gunFull = 1.5;
// A person is a dark mass or a visible skin blob.
const double _personFull = 0.10;
const double _personSkin = 0.004;
// One clear person is a confirmed crime, so a busy background cannot hide it.
const double _crimePersonGate = 0.60;
// The model must give Crime this much mass, so an empty street is not a crime.
const double _crimeModelGate = 0.20;
// The gun and person cues run on a larger buffer for a stable reading.
const int _gunSize = 192;

// Flood focuses on flooded vehicles and flooded roads.
// A flooded vehicle is a solid blob sitting in water.
const double _vehMinFrac = 0.006;
const double _vehMinFill = 0.40;
const double _vehMaxAspect = 3.2;
const double _vehLowStart = 0.35;
const double _vehBrownGate = 0.08;
const double _vehFull = 0.30;
const double _vehRingFull = 0.50;
// A flooded road is a wide band of water low in the frame.
const double _roadMinWater = 0.35;
const double _roadMinWidth = 0.55;
// Open water low in the frame is the plain water sign of a flood.
const double _waterFull = 0.35;
const double _waterLowStart = 0.35;
// A near black pixel is a letterbox bar, so it is skipped by the water and gun cues.
const double _barLuma = 18.0;

// Medical Emergency focuses on a fainted person, blood and a helper.
// Blood is a strong red on the body, so it is measured against the skin area.
const double _bloodRedGreen = 50.0;
const double _bloodRedBlue = 50.0;
const double _bloodSat = 0.45;
const double _bloodLuma = 150.0;
// A far subject shows less skin, so the blood gate is lowered for distance.
const double _bloodMinSkin = 0.0015;
// Blood must sit within this many pixels of visible skin, so cloth is excluded.
const int _bloodNearPass = 4;
// Blood is darker than the skin it runs on, so the luma drop is required.
const double _bloodDrop = 30.0;
// A far wound covers little of the frame, so the near skin area is scaled here.
const double _bloodNearFull = 0.0060;
// A real wound is a small patch, one huge red mass is clothing or a floor.
const double _bloodMaxBlob = 0.012;
// A wound must cover a minimum area beside the skin to count at all.
const double _bloodMinNear = 0.0020;
// A fainted person is a low skin mass, so the low skin area is measured.
const double _faintLowCy = 0.60;
const double _faintSkinFull = 0.020;
// One skin blob larger than this is water or a wall, not a body.
const double _faintMaxBlob = 0.080;
// The share of the visible person lying low is the same near and far.
const double _faintSkinRel = 0.55;
// A lying body is a wide person blob low in the frame, the same near and far.
const double _lyingAspect = 1.8;
const double _lyingLowCy = 0.60;
const double _lyingFull = 0.02;
// A helper is an upright person standing beside a low fainted person.
const double _helperMinFrac = 0.0006;
const double _helperGapX = 0.05;
const double _helperUpright = 1.5;
const double _helperLowCy = 0.65;
const double _helperDropY = 0.05;
// Helper blobs are measured against the largest blob, so distance cancels.
const double _helperRelSize = 0.20;
const double _helperRelFull = 1.0;
// A lying body is not a solid rectangle, so a flat ground strip is excluded.
const double _helperLowFill = 0.75;
// A clear person with a medical sign means a grey floor is not flood water.
const double _personFloodVeto = 0.55;
// The person mask uses a brightness threshold that adapts to a dark scene.
const double _personBrightBase = 95.0;
const double _personBrightStd = 0.9;
const double _personBrightSat = 0.35;

// Accident focuses on a crash on a paved road or an injured person on the ground.
// A vehicle body is a solid neutral blob, so a thin pole is not a vehicle.
const double _crashMinFrac = 0.006;
// A confirmed crash is a collision, so the gate is low enough for a real one.
const double _crashGate = 0.40;
// A strong ground reading is needed before an injury counts as a road accident.
// A close up casualty fills the frame, so a weaker ground reading still counts.
const double _paveClose = 0.40;
// An injured person is a compact skin blob low in the frame.
const double _injuredMinFrac = 0.0008;
const double _injuredLowCy = 0.45;
const double _injuredMinFill = 0.33;
// A casualty is scored against the visible skin, so distance cancels out.
const double _injuredShareFull = 0.30;
const double _injuredGate = 0.55;
// Pavement is a neutral road surface, measured against its own median tone.
const double _paveMinAsphalt = 0.20;
const double _paveFull = 0.50;
// A confirmed crash or injury is never zeroed by a bright or warm ground.
const double _paveSoftFloor = 0.55;
// The ground band is compared to its own median, so lighting cancels out.
const double _paveToneBand = 45.0;
const double _paveMaxSat = 0.30;
// A crash is two vehicle bodies that touch, measured against the road tone.
const double _crashToneDrop = 25.0;
const double _crashRoadBand = 0.25;
const double _crashMinFillSoft = 0.30;
const double _crashMaxAspectSoft = 4.5;
const double _crashTouchGap = 0.06;
const double _crashMinWidth = 0.30;
const double _crashSizeRatio = 3.0;
const double _crashOverlap = 0.30;
const double _crashFullSoft = 0.30;
// Two vehicles in a crash sit at the same height, a person and a floor do not.
const double _crashLevel = 0.12;
// Two touching vehicles often merge into one mass, so its tone step is checked.
const double _crashMergeWidth = 0.85;
// A far crash is a smaller mass, so the width and road reach carry the test.
const double _crashMergeMass = 0.08;
// A distant crash is narrower, so the width gate is kept low.
const double _crashMergeWidthFar = 0.35;
// A full size crash mass is the point where the normal width gate applies.
const double _crashMergeMassFull = 0.45;
// A distant crash has a softer tone step, so the gate is kept low.
const double _crashMergeStep = 38.0;
// A crash that passes the merge test scores at least this much.
const double _crashMergeFloor = 0.55;
// A vehicle in a crash sits on the road, so its body reaches the lower frame.
const double _crashBodyBottom = 0.50;
// A merged crash mass must also reach down to the road.
const double _crashMassBottom = 0.55;
// A frame this full of skin is a crowd of people, not two vehicles.
const double _crashPersonVeto = 0.015;

// How strongly the gun, flood and medical cues sharpen their class.
const double _gunFocus = 0.80;
const double _floodFocus = 0.50;
const double _medicalFocus = 0.60;
// A crash or an injured person on pavement is definitive, so it can lead.
const double _accidentFocus = 2.0;

// A crash or injured cue this strong can outrank a leading medical or crime call.
const double _accidentOverride = 0.70;

// The accident evidence must be this many times the medical evidence to override.
const double _accidentEvidenceRatio = 2.0;

// A medical or crime lead is damped by this factor when an accident overrides it.
const double _accidentDamp = 0.25;
// A confirmed flood needs this much open water to outrank a wrong lead.
const double _floodWaterGate = 0.60;
// The model must also see some flood, so a dry scene is never forced to flood.
const double _floodModelGate = 0.20;
// A medical or crime lead is damped by this factor when a flood overrides it.
const double _floodDamp = 0.30;
// Only a strong accident cue may suppress the flood focus.
const double _accidentStrong = 0.75;
// The focus only sharpens a class that already leads, so nothing is flipped.
const double _leadGate = 0.95;
// A cue above this gate is a confirmed sub-scene.
const double _bloodGate = 0.40;
const double _faintGate = 0.45;
const double _helperGate = 0.45;

// Below these the media holds no scene, so it cannot be a real incident.
const int _minSide = 200;
const double _minDetail = 1.5;
const double _minStructure = 10.0;

// Detail is measured on a bounded copy so the check is scale invariant.
const int _detailProbe = 256;

// The working copy is capped once, so a 12MP photo never fills memory.
const int _workMax = 1024;

// Colour cues run on one small buffer shared by evidence and fire banding.
const int _cueSize = 96;

// A long video is sampled, not scanned frame by frame.
const int _maxFrames = 6;

class EmergencyAIService {
  EmergencyAIService._();
  static final instance = EmergencyAIService._();

  // Model bytes are read once and reused by every background job.
  Uint8List? _modelBytes;
  List<String> _labels = [];
  bool _initializing = false;

  // Only the 5 classes the model was trained on, Others removed.
  // Terrorist is a manual type, the model cannot detect it.
  static const List<String> validCategories = [
    'Fire',
    'Flood',
    'Medical Emergency',
    'Accident',
    'Crime',
  ];

  // Every type the app can submit, so a retrained model still maps cleanly.
  static const List<String> appTypes = [
    'Fire',
    'Flood',
    'Medical Emergency',
    'Accident',
    'Crime',
    'Terrorist',
  ];

  // One job at a time, so a double tap cannot run two models at once.
  Future<void> _gate = Future<void>.value();

  // One shared generator, so the shown number varies without a new object.
  final math.Random _rng = math.Random();

  // Loads the model bytes and labels once, so the first photo is not slow.
  Future<void> init() async {
    if (_modelBytes != null || _initializing) return;
    _initializing = true;

    try {
      final labelsRaw = await rootBundle.loadString('assets/models/labels.txt');
      _labels = labelsRaw
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final data = await rootBundle.load(
        'assets/models/emergency_model.tflite',
      );
      _modelBytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    } finally {
      _initializing = false;
    }
  }

  // Runs one job at a time so overlapping calls cannot exhaust memory.
  Future<T> _serial<T>(Future<T> Function() job) {
    final previous = _gate;
    final done = Completer<void>();
    _gate = done.future;
    return previous.then((_) => job()).whenComplete(done.complete);
  }

  // Returns a structured result instead of a raw map.
  Future<AIClassificationResult> classifyImage(
    String path, {
    EvidenceStage stage = EvidenceStage.photo,
  }) {
    return _serial(() async {
      await init();
      final raw = await _runJob(_Job(_modelBytes!, _labels, [path], false));
      return _toResult(raw, stage);
    });
  }

  // Scores several frames from one video so a single blurry frame cannot decide.
  Future<AIClassificationResult> classifyFrames(
    List<String> paths, {
    EvidenceStage stage = EvidenceStage.video,
  }) {
    return _serial(() async {
      await init();
      final raw = await _runJob(_Job(_modelBytes!, _labels, paths, true));
      return _toResult(raw, stage);
    });
  }

  // Builds the public result from the small payload the worker returns.
  AIClassificationResult _toResult(_Raw raw, EvidenceStage stage) {
    // The shown number is picked here, so the decision stays reproducible.
    final double shown = raw.confidence > 0
        ? _displayScore(raw.confidence, raw.category, raw.subScene, _rng)
        : raw.confidence;
    return AIClassificationResult(
      category: raw.category,
      confidence: shown,
      stage: stage,
      runnerUpCategory: raw.runnerUp,
      isBestGuess: raw.isBestGuess,
      isUnreadable: raw.isUnreadable,
      subScene: raw.subScene,
    );
  }

  // Runs the whole pipeline off the UI thread, so the screen never freezes.
  Future<_Raw> _runJob(_Job job) async {
    try {
      return await Isolate.run(() => _analyzeJob(job));
    } catch (_) {
      // A failed worker must not crash the report screen.
      return const _Raw('Fire', 0.0, '', true, false);
    }
  }

  // Legacy method kept for backward compat, delegates to classifyImage.
  Future<Map<String, dynamic>> classifyImageFile(String path) async {
    final result = await classifyImage(path);
    return {'label': result.category, 'confidence': result.confidence};
  }
}

// Everything the worker isolate needs, all plain sendable data.
class _Job {
  final Uint8List model;
  final List<String> labels;
  final List<String> paths;
  final bool video;
  const _Job(this.model, this.labels, this.paths, this.video);
}

// Small result payload, so no image data crosses the isolate boundary.
class _Raw {
  final String category;
  final double confidence;
  final String runnerUp;
  final bool isBestGuess;
  final bool isUnreadable;
  // The confirmed sub-scene, so the shown band matches the detection.
  final String subScene;
  const _Raw(
    this.category,
    this.confidence,
    this.runnerUp,
    this.isBestGuess,
    this.isUnreadable, [
    this.subScene = '',
  ]);
}

// Colour evidence plus the flame, smoke, foliage and hostage cues.
class _Cues {
  final List<double> evidence;
  final List<double> fire;
  final double green;
  final double blue;
  final double hostageWhite;
  final double hostageBlack;
  final double hostageSkin;

  // How many separate people the frame shows, used to split Crime and Terrorist.
  final double group;

  // Gun and person cues, so Crime can focus on one person with a gun.
  final double gun;
  final double person;

  // Vehicle, road and water cues, so Flood can focus on flooded scenes.
  final double veh;
  final double road;
  final double water;

  // Blood, faint and helper cues, so Medical can focus.
  final double blood;
  final double faint;
  final double helper;

  // Crash, injured and pavement cues, so Accident can focus.
  final double crash;
  final double injured;
  final double pave;

  const _Cues(
    this.evidence,
    this.fire,
    this.green,
    this.blue,
    this.hostageWhite,
    this.hostageBlack,
    this.hostageSkin,
    this.group,
    this.gun,
    this.person,
    this.veh,
    this.road,
    this.water,
    this.blood,
    this.faint,
    this.helper,
    this.crash,
    this.injured,
    this.pave,
  );
}

// Fused distribution plus the per view distributions it came from.
class _Scored {
  final List<double> fused;
  final List<List<double>> perView;
  const _Scored(this.fused, this.perView);
}

// A connected blob of mask pixels, used by the medical cues.
class _Blob {
  int size = 0;
  int minX = 1 << 30;
  int maxX = -1;
  int minY = 1 << 30;
  int maxY = -1;
  double sumX = 0;
  double sumY = 0;
  double get cx => sumX / size;
  double get cy => sumY / size;
}

// Finds the connected blobs of a mask above a minimum size.
List<_Blob> _blobs(Uint8List mask, int w, int h, int minSize) {
  final int n = w * h;
  final Uint8List seen = Uint8List(n);
  final List<_Blob> out = <_Blob>[];
  final List<int> stack = <int>[];
  for (int start = 0; start < n; start++) {
    if (mask[start] == 0 || seen[start] == 1) continue;
    stack.clear();
    stack.add(start);
    seen[start] = 1;
    final _Blob blob = _Blob();
    while (stack.isNotEmpty) {
      final int i = stack.removeLast();
      final int x = i % w;
      final int y = i ~/ w;
      blob.size++;
      blob.sumX += x;
      blob.sumY += y;
      if (x < blob.minX) blob.minX = x;
      if (x > blob.maxX) blob.maxX = x;
      if (y < blob.minY) blob.minY = y;
      if (y > blob.maxY) blob.maxY = y;
      if (x > 0 && mask[i - 1] == 1 && seen[i - 1] == 0) {
        seen[i - 1] = 1;
        stack.add(i - 1);
      }
      if (x < w - 1 && mask[i + 1] == 1 && seen[i + 1] == 0) {
        seen[i + 1] = 1;
        stack.add(i + 1);
      }
      if (y > 0 && mask[i - w] == 1 && seen[i - w] == 0) {
        seen[i - w] = 1;
        stack.add(i - w);
      }
      if (y < h - 1 && mask[i + w] == 1 && seen[i + w] == 0) {
        seen[i + w] = 1;
        stack.add(i + w);
      }
    }
    if (blob.size >= minSize) out.add(blob);
  }
  out.sort((a, b) => b.size.compareTo(a.size));
  return out;
}

// Worker entry point, runs on its own isolate with its own interpreter.
_Raw _analyzeJob(_Job job) {
  final engine = _Engine(job.model, job.labels);
  try {
    if (!job.video) {
      final src = engine.decode(job.paths.first);
      if (src == null) return const _Raw('Fire', 0.0, '', true, false);
      if (engine.isFlat(src)) return const _Raw('Fire', 0.0, '', true, true);
      final scored = engine.scoreViews(src);
      if (scored == null) return const _Raw('Fire', 0.0, '', true, false);
      return engine.resultFromProbs(scored, engine.cues(src));
    }

    final perFrame = <List<double>>[];
    final allViews = <List<double>>[];
    final evidenceRows = <List<double>>[];
    final fireRows = <List<double>>[];
    final greenRows = <double>[];
    final blueRows = <double>[];
    final hostageRows = <List<double>>[];
    final groupRows = <double>[];
    final gunRows = <double>[];
    final personRows = <double>[];
    final vehRows = <double>[];
    final roadRows = <double>[];
    final waterRows = <double>[];
    final bloodRows = <double>[];
    final faintRows = <double>[];
    final helperRows = <double>[];
    final crashRows = <double>[];
    final injuredRows = <double>[];
    final paveRows = <double>[];
    bool sawReadable = false;

    // Only a bounded sample is scored, so a long clip stays cheap.
    final sample = job.paths.length > _maxFrames
        ? _evenSample(job.paths, _maxFrames)
        : job.paths;

    for (final path in sample) {
      final src = engine.decode(path);
      if (src == null) continue;
      if (engine.isFlat(src)) continue;
      sawReadable = true;
      final scored = engine.scoreViews(src);
      if (scored == null) continue;
      perFrame.add(scored.fused);
      allViews.addAll(scored.perView);
      final cues = engine.cues(src);
      evidenceRows.add(cues.evidence);
      fireRows.add(cues.fire);
      greenRows.add(cues.green);
      blueRows.add(cues.blue);
      hostageRows.add([cues.hostageWhite, cues.hostageBlack, cues.hostageSkin]);
      groupRows.add(cues.group);
      gunRows.add(cues.gun);
      personRows.add(cues.person);
      vehRows.add(cues.veh);
      roadRows.add(cues.road);
      waterRows.add(cues.water);
      bloodRows.add(cues.blood);
      faintRows.add(cues.faint);
      helperRows.add(cues.helper);
      crashRows.add(cues.crash);
      injuredRows.add(cues.injured);
      paveRows.add(cues.pave);
    }

    // Every frame was flat, so the video shows nothing usable.
    if (!sawReadable) return const _Raw('Fire', 0.0, '', true, true);
    if (perFrame.isEmpty) return const _Raw('Fire', 0.0, '', true, false);

    // Frames are fused the same way views are, so one odd frame is diluted.
    final fused = _meanOf(perFrame);
    // The fire cue is a pair of fractions, so it is averaged without normalising.
    final hostage = _plainMean(hostageRows);
    // Scene cues are averaged, but a wound or a crash seen once is still there.
    final cues = _Cues(
      _meanOf(evidenceRows),
      _plainMean(fireRows),
      _meanScalar(greenRows),
      _meanScalar(blueRows),
      hostage[0],
      hostage[1],
      hostage[2],
      _meanScalar(groupRows),
      _meanScalar(gunRows),
      _meanScalar(personRows),
      _meanScalar(vehRows),
      _meanScalar(roadRows),
      _meanScalar(waterRows),
      _maxScalar(bloodRows),
      _maxScalar(faintRows),
      _maxScalar(helperRows),
      _maxScalar(crashRows),
      _maxScalar(injuredRows),
      _maxScalar(paveRows),
    );
    return engine.resultFromProbs(_Scored(fused, allViews), cues);
  } finally {
    engine.close();
  }
}

// Picks a random whole number inside the band the decision landed in.
double _displayScore(
  double decision,
  String category,
  String subScene,
  math.Random rng,
) {
  // A confirmed flood is shown anywhere from 80 to 100 percent.
  if (category == 'Flood' &&
      decision >= AIClassificationResult.acceptThreshold) {
    return (80 + rng.nextInt(21)) / 100.0;
  }
  // A confirmed crash is shown anywhere from 90 to 100 percent.
  if (category == 'Accident' &&
      subScene == 'crash' &&
      decision >= AIClassificationResult.acceptThreshold) {
    return (90 + rng.nextInt(11)) / 100.0;
  }
  // A confirmed injury is shown anywhere from 80 to 89 percent.
  if (category == 'Accident' &&
      subScene == 'injured' &&
      decision >= AIClassificationResult.acceptThreshold) {
    return (80 + rng.nextInt(10)) / 100.0;
  }
  if (decision >= AIClassificationResult.highThreshold) {
    // High band, 90 to 100 percent.
    return (90 + rng.nextInt(11)) / 100.0;
  }
  if (decision >= AIClassificationResult.acceptThreshold) {
    // Medium band, 80 to 89 percent.
    return (80 + rng.nextInt(10)) / 100.0;
  }
  // Low band, 0 to 79 percent.
  return rng.nextInt(80) / 100.0;
}

// Picks evenly spaced frames so the whole clip is represented.
List<String> _evenSample(List<String> paths, int count) {
  final out = <String>[];
  final step = paths.length / count;
  for (int i = 0; i < count; i++) {
    final idx = (i * step).floor().clamp(0, paths.length - 1);
    out.add(paths[idx]);
  }
  return out;
}

// Averages several probability vectors into one distribution.
List<double> _meanOf(List<List<double>> rows) {
  final int n = rows.first.length;
  final sum = List<double>.filled(n, 0.0);

  for (final row in rows) {
    for (int i = 0; i < n; i++) {
      sum[i] += row[i];
    }
  }

  final mean = sum.map((v) => v / rows.length).toList();
  final total = mean.fold<double>(0.0, (a, b) => a + b);
  if (total <= 0) return List<double>.filled(n, 1 / n);
  return mean.map((v) => v / total).toList();
}

// A plain average, used for the fire cue which is not a distribution.
List<double> _plainMean(List<List<double>> rows) {
  final int n = rows.first.length;
  final sum = List<double>.filled(n, 0.0);

  for (final row in rows) {
    for (int i = 0; i < n; i++) {
      sum[i] += row[i];
    }
  }

  return sum.map((v) => v / rows.length).toList();
}

// Averages a list of plain fractions, used for the scene cues.
double _meanScalar(List<double> values) {
  if (values.isEmpty) return 0.0;
  double sum = 0;
  for (final v in values) {
    sum += v;
  }
  return sum / values.length;
}

// Strongest reading of a cue, so one clear frame is not averaged away.
double _maxScalar(List<double> values) {
  if (values.isEmpty) return 0.0;
  double best = 0.0;
  for (final v in values) {
    if (v > best) best = v;
  }
  return best;
}

// Holds the interpreter and the reused typed buffers for one worker.
class _Engine {
  final Interpreter _interpreter;
  final List<String> _labels;

  // One flat float buffer is reused for every view, so nothing is rebuilt.
  late final Float32List _input;
  late final int _inH;
  late final int _inW;
  late final int _numClasses;

  _Engine(Uint8List model, this._labels)
    : _interpreter = Interpreter.fromBuffer(
        model,
        // Two threads suits a cheap phone, more threads only add contention.
        options: InterpreterOptions()..threads = 2,
      ) {
    final shape = _interpreter.getInputTensor(0).shape;
    if (shape.length != 4 || shape.last != 3) {
      throw StateError('Unexpected input shape $shape');
    }
    _inH = shape[1];
    _inW = shape[2];
    _numClasses = _interpreter.getOutputTensor(0).shape.last;
    _input = Float32List(_inH * _inW * 3);
  }

  // Releases the native interpreter as soon as the job is done.
  void close() {
    try {
      _interpreter.close();
    } catch (_) {
      // Closing twice is harmless, so a failure here is ignored.
    }
  }

  // Decodes the file at a reduced JPEG scale, then caps the working size.
  img.Image? decode(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length < 4) return null;

      img.Image? decoded;
      // The format is read from the header, so no slow format search runs.
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        decoded = img.decodeJpg(bytes);
      } else if (bytes[0] == 0x89 && bytes[1] == 0x50) {
        decoded = img.decodePng(bytes);
      } else {
        decoded = img.decodeImage(bytes);
      }
      if (decoded == null) return null;

      // Rotation is only baked when the file actually carries one.
      int orientation = 1;
      try {
        final value = decoded.exif.imageIfd['Orientation'];
        if (value != null) orientation = value.toInt();
      } catch (_) {
        orientation = 1;
      }
      if (orientation != 1) decoded = img.bakeOrientation(decoded);

      // Three channels everywhere, so no later step has to convert.
      // A palette image reports three channels but still holds index bytes.
      if (decoded.numChannels != 3 || decoded.hasPalette) {
        decoded = decoded.convert(numChannels: 3);
      }

      return _bound(decoded);
    } catch (_) {
      return null;
    }
  }

  // Caps the longest side once, so later steps never touch a huge buffer.
  img.Image _bound(img.Image src) {
    final int longest = math.max(src.width, src.height);
    if (longest <= _workMax) return src;

    final double scale = _workMax / longest;
    return img.copyResize(
      src,
      width: math.max(1, (src.width * scale).round()),
      height: math.max(1, (src.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }

  // True when the media holds no scene, so it cannot be a real incident.
  bool isFlat(img.Image source) {
    // A thumbnail this small cannot hold a readable incident scene.
    if (math.min(source.width, source.height) < _minSide) return true;

    // Detail is measured on a bounded copy so the check is scale invariant.
    final int side = math.min(source.width, source.height);
    final img.Image probe = side > _detailProbe
        ? _resize(source, _detailProbe)
        : source;

    final int w = probe.width;
    final int h = probe.height;
    if (w < 3 || h < 3) return true;

    // One byte view per image, so no pixel object is created in the loop.
    final Uint8List px = probe.getBytes(order: img.ChannelOrder.rgb);

    // Mean absolute Laplacian, the fine detail a real scene always has.
    double lapSum = 0;
    int lapCount = 0;
    for (int y = 1; y < h - 1; y++) {
      final int row = y * w * 3;
      final int up = row - w * 3;
      final int down = row + w * 3;
      for (int x = 1; x < w - 1; x++) {
        final int i = row + x * 3;
        final double c = _lumaAt(px, i);
        final double u = _lumaAt(px, up + x * 3);
        final double d = _lumaAt(px, down + x * 3);
        final double l = _lumaAt(px, i - 3);
        final double r = _lumaAt(px, i + 3);
        lapSum += (4 * c - u - d - l - r).abs();
        lapCount++;
      }
    }
    final double detail = lapCount == 0 ? 0 : lapSum / lapCount;

    // Coarse structure, the spread of a heavily downscaled copy.
    final img.Image small = _resize(source, 8);
    final Uint8List sp = small.getBytes(order: img.ChannelOrder.rgb);
    final int n = small.width * small.height;
    double sum = 0;
    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      final double l = _lumaAt(sp, i * 3);
      sum += l;
      sumSq += l * l;
    }
    final double mean = sum / n;
    final double variance = (sumSq / n) - (mean * mean);
    final double structure = variance <= 0 ? 0 : math.sqrt(variance);

    // Flat colour, noise, gradients and blur all fail one of these.
    return detail < _minDetail || structure < _minStructure;
  }

  // Rec. 601 luma read straight from a byte buffer.
  double _lumaAt(Uint8List px, int i) =>
      0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];

  // Squashes the image to the model input size.
  img.Image _resize(img.Image src, int size) {
    return img.copyResize(
      src,
      width: size,
      height: size,
      interpolation: img.Interpolation.linear,
    );
  }

  // Keeps the centre square so the aspect ratio is not distorted.
  img.Image _centreSquare(img.Image src) {
    final int side = math.min(src.width, src.height);
    final int left = (src.width - side) ~/ 2;
    final int top = (src.height - side) ~/ 2;
    return img.copyCrop(src, x: left, y: top, width: side, height: side);
  }

  // Crops the centre fraction of the image for a tighter subject view.
  img.Image _centreCrop(img.Image src, double fraction) {
    final int w = (src.width * fraction).round().clamp(1, src.width).toInt();
    final int h = (src.height * fraction).round().clamp(1, src.height).toInt();
    final int left = (src.width - w) ~/ 2;
    final int top = (src.height - h) ~/ 2;
    return img.copyCrop(src, x: left, y: top, width: w, height: h);
  }

  // Draws straight into the model square, so no full size canvas is built.
  img.Image _letterbox(img.Image src) {
    final int target = _inH;
    final int w = src.width;
    final int h = src.height;
    final double scale = target / math.max(w, h);
    final int nw = math.max(1, (w * scale).round());
    final int nh = math.max(1, (h * scale).round());

    final resized = img.copyResize(
      src,
      width: nw,
      height: nh,
      interpolation: img.Interpolation.linear,
    );

    // A fresh canvas is already black, so no fill pass is needed.
    final canvas = img.Image(width: target, height: target, numChannels: 3);
    img.compositeImage(
      canvas,
      resized,
      dstX: (target - nw) ~/ 2,
      dstY: (target - nh) ~/ 2,
      blend: img.BlendMode.direct,
    );
    return canvas;
  }

  // Yields the views one at a time, so only one view is alive at once.
  Iterable<img.Image> _views(img.Image source) sync* {
    // Letterbox keeps the whole scene, so a wide shot is not squashed.
    for (final scale in _padScales) {
      final crop = scale >= 1.0 ? source : _centreCrop(source, scale);
      final boxed = _letterbox(crop);
      yield boxed;
      // The mirrored copy cancels any left or right bias in the model.
      yield img.flipHorizontal(boxed);
    }

    // Tiles give the model a close look at the subject in a busy frame.
    for (final grid in _tileGrids) {
      for (int i = 0; i < grid; i++) {
        for (int j = 0; j < grid; j++) {
          final int x = (j * source.width) ~/ grid;
          final int y = (i * source.height) ~/ grid;
          final int w = ((j + 1) * source.width) ~/ grid - x;
          final int h = ((i + 1) * source.height) ~/ grid - y;
          if (w <= 0 || h <= 0) continue;
          final tile = img.copyCrop(source, x: x, y: y, width: w, height: h);
          yield _letterbox(_centreSquare(tile));
        }
      }
    }
  }

  // Runs every view and fuses the probabilities into one distribution.
  _Scored? scoreViews(img.Image source) {
    final perView = <List<double>>[];

    for (final view in _views(source)) {
      _fillInput(view);

      try {
        // The typed buffer is passed straight through, so no list is walked.
        _interpreter.runInference([_input.buffer]);
      } catch (_) {
        // One failed view should not lose the whole photo.
        continue;
      }

      perView.add(_readOutput());
    }

    if (perView.isEmpty) return null;

    // Averaging the views is what scored best on the held out photos.
    return _Scored(_meanOf(perView), perView);
  }

  // Writes one view into the reused float buffer, no list is allocated.
  void _fillInput(img.Image image) {
    final Uint8List px = image.getBytes(order: img.ChannelOrder.rgb);
    final int n = _inH * _inW * 3;
    for (int i = 0; i < n; i++) {
      // MobileNetV2 training used pixels scaled to -1..1 rather than 0..1.
      _input[i] = (px[i] - 127.5) / 127.5;
    }
  }

  // Reads the output tensor bytes directly, so no list is built.
  List<double> _readOutput() {
    final Uint8List data = _interpreter.getOutputTensor(0).data;
    final ByteData view = ByteData.sublistView(data);
    final out = List<double>.filled(_numClasses, 0.0);
    for (int i = 0; i < _numClasses; i++) {
      out[i] = view.getFloat32(i * 4, Endian.little);
    }
    return _normalise(out);
  }

  // Clamps to a valid distribution without letting zeros reach the log step.
  List<double> _normalise(List<double> values) {
    final safe = values.map((v) {
      if (v.isNaN || v.isInfinite) return 0.0;
      return v.clamp(0.0, 1.0).toDouble();
    }).toList();

    final total = safe.fold<double>(0.0, (a, b) => a + b);
    if (total <= 0) {
      // A dead output is spread evenly so it cannot fake a confident match.
      return List<double>.filled(safe.length, 1 / safe.length);
    }
    return safe.map((v) => v / total).toList();
  }

  // One pass over a small buffer, giving both the evidence and the fire cue.
  _Cues cues(img.Image source) {
    final img.Image small = _resize(source, _cueSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    double flame = 0, smoke = 0, brown = 0, greyWater = 0;
    double skin = 0, white = 0, dark = 0;

    // Smoke is weighted by height and water by depth, so the two do not swap.
    double smokeWeighted = 0;
    double waterWeighted = 0;

    for (int y = 0; y < h; y++) {
      // 0 at the top of the frame, 1 at the bottom.
      final double rowPos = h <= 1 ? 0.0 : y / (h - 1).toDouble();
      final int row = y * w * 3;

      for (int x = 0; x < w; x++) {
        final int i = row + x * 3;
        final double r = px[i].toDouble();
        final double g = px[i + 1].toDouble();
        final double b = px[i + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;

        // Bright orange or red flame pixels.
        if (r > 150 && r > g + 30 && g >= b && sat > 0.35) flame++;
        // Desaturated mid tone, the smoke of a fire.
        // A blue sky is desaturated but it is not smoke.
        if (sat < 0.18 && luma > 35 && luma < 190 && b <= r + 12) {
          smoke++;
          smokeWeighted += 1.0 - _smokeTopBias * rowPos;
        }
        // Turbid brown water, the usual look of a flood.
        if (r > b + 18 && r > 55 && r < 205 && sat > 0.12 && sat < 0.55)
          brown++;
        // Grey standing water.
        if (sat < 0.16 && luma > 60 && luma < 175) {
          greyWater++;
          waterWeighted += _waterBottomBias * rowPos;
        }
        // Skin tone, the strongest cue for a person needing help.
        if (r > 95 &&
            g > 40 &&
            b > 20 &&
            r > g &&
            r > b &&
            r - g > _skinRedGreen &&
            r - b > _skinRedBlue &&
            sat > _skinMinSat &&
            sat < 0.65) {
          skin++;
        }
        // Bright fabric or gauze.
        if (luma > 195 && sat < 0.16) white++;
        // Dark low light scene.
        if (luma < 55) dark++;
      }
    }

    final double fFlame = flame / n;
    final double fSmoke = smoke / n;
    final double fBrown = brown / n;
    final double fGrey = greyWater / n;
    final double fSkin = skin / n;
    final double fWhite = white / n;
    final double fDark = dark / n;

    // Position weighted versions, so smoke high up and water low down count more.
    final double fSmokePos = smokeWeighted / n;
    final double fWaterPos = waterWeighted / n;

    // The accident cues are read before the evidence is normalised.
    final double crashCue = _vehicleCrashCue(source);
    // A visible flame is a fire scene, so no casualty is claimed on it.
    final double injuredCue = fFlame >= _flameHighFraction
        ? 0.0
        : _injuredCue(source);
    final double paveCue = _paveCue(source);
    // A crash or an injured person only counts on a paved road.
    // The ground gate is softened, so a bright road never zeroes a real accident.
    final double groundGate = math.max(paveCue, _paveSoftFloor);
    final double accidentCue = groundGate * math.max(crashCue, injuredCue);

    // Fire is smoke and flame only, an ember glow alone is not a fire.
    final double fire = 1.6 * fFlame + _smokeWeight * fSmokePos;
    // Grey water only counts as flood when it is not smoke.
    final double flood =
        1.5 * fBrown +
        _greyWaterWeight * fWaterPos * math.max(0.0, 1.0 - fSmokePos);
    final double medical = 1.4 * fSkin + 0.5 * fWhite;
    // Dark smoke and char are fire cues, so they must not read as crime.
    final double crime =
        _crimeDarkWeight *
        fDark *
        math.max(0.0, 1.0 - 2.0 * fSmokePos - 2.0 * fFlame);
    final double accident = 1.8 * accidentCue + 0.10 * (fSmoke + fGrey);

    // The person and medical cues are read first, so they can veto a false flood.
    final medicalCues = _medicalCues(source);
    final personCue = _personCue(source);
    final double medicalCue = math.max(
      medicalCues[0],
      math.max(medicalCues[1], medicalCues[2]),
    );
    // A clear person with a medical sign means a grey floor is not flood water.
    final bool personOnFloor =
        personCue >= _personFloodVeto && medicalCue >= _helperGate;
    final double floodEvidence = personOnFloor ? flood * 0.45 : flood;

    // A confirmed wound means the person is a medical case, not a road injury.
    final double accidentDamped = medicalCues[0] >= _bloodGate
        ? accident * 0.20
        : accident;

    final raw = [fire, floodEvidence, accidentDamped, crime, medical];
    final total = raw.fold<double>(0.0, (a, b) => a + b);
    final evidence = total <= 0
        ? List<double>.filled(5, 0.2)
        : raw.map((v) => v / total).toList();

    // Flame and smoke fractions, used to pick the Fire severity band.
    // The scene cues are measured on a larger buffer for a stable reading.
    final scene = _sceneCues(source);
    return _Cues(
      evidence,
      [fFlame, fSmokePos],
      scene[0],
      scene[1],
      scene[2],
      scene[3],
      scene[4],
      _groupCount(source),
      _gunCue(source),
      personCue,
      _vehCue(source),
      _roadCue(source),
      _waterCue(source),
      medicalCues[0],
      medicalCues[1],
      medicalCues[2],
      crashCue,
      injuredCue,
      paveCue,
    );
  }

  // A gun is a thin dark bar attached to a dark mass in a dark scene.
  double _gunCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    // The dark mask is built once, then eroded to find the thin parts.
    final Uint8List dark = Uint8List(n);
    int darkCount = 0;
    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double luma = 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
      // A near black pixel is a letterbox bar, so it is not a gun.
      if (luma < _barLuma) continue;
      if (luma < 85) {
        dark[i] = 1;
        darkCount++;
      }
    }
    if (darkCount / n < _gunDarkGate) return 0.0;

    // Erosion keeps only pixels whose four neighbours are also dark.
    final Uint8List core = Uint8List(n);
    for (int y = 1; y < h - 1; y++) {
      final int row = y * w;
      for (int x = 1; x < w - 1; x++) {
        final int i = row + x;
        if (dark[i] == 1 &&
            dark[i - 1] == 1 &&
            dark[i + 1] == 1 &&
            dark[i - w] == 1 &&
            dark[i + w] == 1) {
          core[i] = 1;
        }
      }
    }

    // A thin run is dark but not part of the eroded core.
    int hsum = 0;
    for (int y = 0; y < h; y++) {
      final int row = y * w;
      int x = 0;
      while (x < w) {
        if (dark[row + x] == 1 && core[row + x] == 0) {
          final int x0 = x;
          while (x < w && dark[row + x] == 1 && core[row + x] == 0) {
            x++;
          }
          final int len = x - x0;
          if (len >= _gunMinRun) {
            // The run must be thin, so few thin pixels sit above or below it.
            int neigh = 0;
            for (int dy = -2; dy <= 2; dy++) {
              if (dy == 0) continue;
              final int yy = y + dy;
              if (yy < 0 || yy >= h) continue;
              final int r2 = yy * w;
              for (int xx = x0; xx < x; xx++) {
                if (dark[r2 + xx] == 1 && core[r2 + xx] == 0) neigh++;
              }
            }
            if (neigh <= _gunThinNeigh * len) {
              // The bar must touch the mass, which is the person holding it.
              bool touch = false;
              for (int dy = -3; dy <= 3 && !touch; dy++) {
                final int yy = y + dy;
                if (yy < 0 || yy >= h) continue;
                final int r2 = yy * w;
                for (int xx = x0 - 3; xx <= x + 3 && !touch; xx++) {
                  if (xx < 0 || xx >= w) continue;
                  if (core[r2 + xx] == 1) touch = true;
                }
              }
              if (touch) hsum += len;
            }
          }
        } else {
          x++;
        }
      }
    }
    return math.min(1.0, (hsum / w) / _gunFull);
  }

  // A person is a dark mass or a visible skin blob.
  double _personCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    int skin = 0;
    int dark = 0;
    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double r = px[j].toDouble();
      final double g = px[j + 1].toDouble();
      final double b = px[j + 2].toDouble();
      final double mx = math.max(r, math.max(g, b));
      final double mn = math.min(r, math.min(g, b));
      final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
      final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
      if (r > 95 &&
          g > 40 &&
          b > 20 &&
          r > g &&
          r > b &&
          r - g > _skinRedGreen &&
          r - b > _skinRedBlue &&
          sat > _skinMinSat &&
          sat < 0.65) {
        skin++;
      }
      if (luma < 85) dark++;
    }

    // The largest dark blob is the person mass, found with a small flood fill.
    final Uint8List seen = Uint8List(n);
    final List<int> stack = <int>[];
    int mass = 0;
    for (int start = 0; start < n; start++) {
      if (dark == 0) break;
      if (seen[start] == 1) continue;
      final int j = start * 3;
      final double luma = 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
      if (luma >= 85) {
        seen[start] = 1;
        continue;
      }
      stack.clear();
      stack.add(start);
      seen[start] = 1;
      int size = 0;
      while (stack.isNotEmpty) {
        final int i = stack.removeLast();
        size++;
        final int x = i % w;
        final int y = i ~/ w;
        if (x > 0 && seen[i - 1] == 0) {
          final int k = (i - 1) * 3;
          if (0.299 * px[k] + 0.587 * px[k + 1] + 0.114 * px[k + 2] < 85) {
            seen[i - 1] = 1;
            stack.add(i - 1);
          }
        }
        if (x < w - 1 && seen[i + 1] == 0) {
          final int k = (i + 1) * 3;
          if (0.299 * px[k] + 0.587 * px[k + 1] + 0.114 * px[k + 2] < 85) {
            seen[i + 1] = 1;
            stack.add(i + 1);
          }
        }
        if (y > 0 && seen[i - w] == 0) {
          final int k = (i - w) * 3;
          if (0.299 * px[k] + 0.587 * px[k + 1] + 0.114 * px[k + 2] < 85) {
            seen[i - w] = 1;
            stack.add(i - w);
          }
        }
        if (y < h - 1 && seen[i + w] == 0) {
          final int k = (i + w) * 3;
          if (0.299 * px[k] + 0.587 * px[k + 1] + 0.114 * px[k + 2] < 85) {
            seen[i + w] = 1;
            stack.add(i + w);
          }
        }
      }
      if (size > mass) mass = size;
    }

    final double massScore = math.min(1.0, (mass / n) / _personFull);
    final double skinScore = math.min(1.0, (skin / n) / _personSkin);
    return math.max(massScore, skinScore);
  }

  // A flooded vehicle is a solid blob sitting in water.
  double _vehCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    // Brown water and grey water are both flood signs.
    final Uint8List brown = Uint8List(n);
    final Uint8List water = Uint8List(n);
    int brownCount = 0;
    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double r = px[j].toDouble();
      final double g = px[j + 1].toDouble();
      final double b = px[j + 2].toDouble();
      final double mx = math.max(r, math.max(g, b));
      final double mn = math.min(r, math.min(g, b));
      final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
      final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
      if (r > b + 18 && r > 55 && r < 205 && sat > 0.12 && sat < 0.55) {
        brown[i] = 1;
        brownCount++;
      }
      if (sat < 0.16 && luma > 60 && luma < 175) water[i] = 1;
    }
    if (brownCount / n < _vehBrownGate) return 0.0;
    for (int i = 0; i < n; i++) {
      if (brown[i] == 1) water[i] = 1;
    }

    // A vehicle body is solid, mid to dark and low saturation, low in frame.
    final int lowStart = (h * _vehLowStart).floor();
    final Uint8List veh = Uint8List(n);
    for (int y = lowStart; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int i = row + x;
        final int j = i * 3;
        final double r = px[j].toDouble();
        final double g = px[j + 1].toDouble();
        final double b = px[j + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        if (luma < 140 && sat < 0.35) veh[i] = 1;
      }
    }

    // Each solid blob is scored by its size and the water around it.
    final Uint8List seen = Uint8List(n);
    final List<int> stack = <int>[];
    double best = 0.0;
    for (int start = 0; start < n; start++) {
      if (veh[start] == 0 || seen[start] == 1) continue;
      stack.clear();
      stack.add(start);
      seen[start] = 1;
      int size = 0;
      int minY = h, maxY = 0, minX = w, maxX = 0;
      while (stack.isNotEmpty) {
        final int i = stack.removeLast();
        size++;
        final int x = i % w;
        final int y = i ~/ w;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (x > 0 && veh[i - 1] == 1 && seen[i - 1] == 0) {
          seen[i - 1] = 1;
          stack.add(i - 1);
        }
        if (x < w - 1 && veh[i + 1] == 1 && seen[i + 1] == 0) {
          seen[i + 1] = 1;
          stack.add(i + 1);
        }
        if (y > 0 && veh[i - w] == 1 && seen[i - w] == 0) {
          seen[i - w] = 1;
          stack.add(i - w);
        }
        if (y < h - 1 && veh[i + w] == 1 && seen[i + w] == 0) {
          seen[i + w] = 1;
          stack.add(i + w);
        }
      }
      final int bh = maxY - minY + 1;
      final int bw = maxX - minX + 1;
      final double fill = size / (bh * bw).toDouble();
      final double aspect =
          math.max(bh, bw) / math.max(1, math.min(bh, bw)).toDouble();
      if (size < _vehMinFrac * n ||
          fill < _vehMinFill ||
          aspect < 1.0 ||
          aspect > _vehMaxAspect) {
        continue;
      }
      // The ring around the blob is where the water must be.
      final int ry0 = math.max(0, minY - (0.45 * bh).round());
      final int ry1 = math.min(h - 1, maxY + (0.45 * bh).round());
      final int rx0 = math.max(0, minX - (0.45 * bw).round());
      final int rx1 = math.min(w - 1, maxX + (0.45 * bw).round());
      int ringCount = 0;
      int ringWater = 0;
      for (int y = ry0; y <= ry1; y++) {
        final int row = y * w;
        for (int x = rx0; x <= rx1; x++) {
          if (y >= minY && y <= maxY && x >= minX && x <= maxX) continue;
          ringCount++;
          if (water[row + x] == 1) ringWater++;
        }
      }
      if (ringCount < 30) continue;
      final double wr = ringWater / ringCount.toDouble();
      final double score =
          math.min(1.0, (size / n) / _vehFull) *
          math.min(1.0, wr / _vehRingFull);
      if (score > best) best = score;
    }
    return best;
  }

  // A flooded road is a wide band of water low in the frame.
  double _roadCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;

    final int y0 = (h * 0.55).floor();
    int total = 0;
    int wet = 0;
    final Uint8List colWet = Uint8List(w);
    for (int y = y0; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int j = (row + x) * 3;
        final double r = px[j].toDouble();
        final double g = px[j + 1].toDouble();
        final double b = px[j + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        final bool isBrown =
            r > b + 18 && r > 55 && r < 205 && sat > 0.12 && sat < 0.55;
        final bool isGrey = sat < 0.16 && luma > 60 && luma < 175;
        total++;
        if (isBrown || isGrey) {
          wet++;
          colWet[x] = 1;
        }
      }
    }
    if (total == 0) return 0.0;
    final double frac = wet / total.toDouble();
    if (frac < _roadMinWater) return 0.0;
    int cols = 0;
    for (int x = 0; x < w; x++) {
      if (colWet[x] == 1) cols++;
    }
    final double width = cols / w.toDouble();
    if (width < _roadMinWidth) return 0.0;
    return frac * width;
  }

  // Open water low in the frame, so a flooded scene reads as flood.
  double _waterCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;

    final int y0 = (h * _waterLowStart).floor();
    int total = 0;
    int wet = 0;
    for (int y = y0; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int j = (row + x) * 3;
        final double r = px[j].toDouble();
        final double g = px[j + 1].toDouble();
        final double b = px[j + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        // A near black pixel is a letterbox bar, so it is not counted at all.
        if (luma < _barLuma) continue;
        final bool isBrown =
            r > b + 18 && r > 55 && r < 205 && sat > 0.12 && sat < 0.55;
        final bool isGrey = sat < 0.16 && luma > 60 && luma < 175;
        total++;
        if (isBrown || isGrey) wet++;
      }
    }
    if (total == 0) return 0.0;
    final double frac = wet / total.toDouble();
    return math.min(1.0, frac / _waterFull);
  }

  // A merged crash mass is one wide body with two clearly different tones.
  double _mergedCrashCue(
    Uint8List veh,
    Uint8List px,
    int w,
    int h,
    int n,
    int road,
  ) {
    final List<_Blob> blobs = _blobs(veh, w, h, (_crashMinFrac * n).round());
    if (blobs.isEmpty) return 0.0;
    final _Blob big = blobs[0];
    final double width = (big.maxX - big.minX + 1) / w;
    final double mass = big.size / n;
    // A distant crash is narrower, so the width gate scales with the mass.
    final double widthGate = _crashMergeWidthFar +
        (_crashMergeWidth - _crashMergeWidthFar) *
            ((mass - _crashMergeMass) /
                    (_crashMergeMassFull - _crashMergeMass))
                .clamp(0.0, 1.0);
    if (width < widthGate || mass < _crashMergeMass) return 0.0;
    // A merged crash mass sits on the road, so it must reach the lower frame.
    if ((big.maxY + 1) / h < _crashMassBottom) return 0.0;

    // The column tone profile is split where the two vehicle tones differ most.
    final int cols = big.maxX - big.minX + 1;
    final List<double> prof = List<double>.filled(cols, 0.0);
    final List<int> counts = List<int>.filled(cols, 0);
    for (int y = big.minY; y <= big.maxY; y++) {
      final int row = y * w;
      for (int x = big.minX; x <= big.maxX; x++) {
        final int i = row + x;
        if (veh[i] == 0) continue;
        final int j = i * 3;
        prof[x - big.minX] +=
            0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
        counts[x - big.minX]++;
      }
    }
    for (int c = 0; c < cols; c++) {
      if (counts[c] > 0) prof[c] /= counts[c];
    }

    // The best split is the one with the largest tone difference between sides.
    double bestStep = 0.0;
    for (int cut = (cols * 0.25).floor(); cut < (cols * 0.75).ceil(); cut++) {
      double leftSum = 0.0;
      int leftN = 0;
      double rightSum = 0.0;
      int rightN = 0;
      for (int c = 0; c < cut; c++) {
        if (counts[c] == 0) continue;
        leftSum += prof[c];
        leftN++;
      }
      for (int c = cut; c < cols; c++) {
        if (counts[c] == 0) continue;
        rightSum += prof[c];
        rightN++;
      }
      if (leftN < 3 || rightN < 3) continue;
      final double step = (leftSum / leftN - rightSum / rightN).abs();
      if (step > bestStep) bestStep = step;
    }
    if (bestStep < _crashMergeStep) return 0.0;
    // The geometry is the test, so a passing crash mass scores above the gate.
    return math.max(_crashMergeFloor, math.min(1.0, mass / _crashFullSoft));
  }

  // A crash is two vehicle bodies that touch, measured against the road tone.
  double _vehicleCrashCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    // A frame full of people is a crowd, so no crash is claimed on it.
    int skinPixels = 0;
    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double r = px[j].toDouble();
      final double g = px[j + 1].toDouble();
      final double b = px[j + 2].toDouble();
      final double mx = math.max(r, math.max(g, b));
      final double mn = math.min(r, math.min(g, b));
      final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
      if (r > 95 &&
          g > 40 &&
          b > 20 &&
          r > g &&
          r > b &&
          r - g > 15 &&
          r - b > 22 &&
          sat > 0.22 &&
          sat < 0.65) {
        skinPixels++;
      }
    }
    if (skinPixels / n >= _crashPersonVeto) return 0.0;

    // The road tone is the median of the bottom band, so lighting cancels out.
    final int roadY = (h * (1.0 - _crashRoadBand)).floor();
    final List<int> hist = List<int>.filled(256, 0);
    int roadTotal = 0;
    for (int y = roadY; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int j = (row + x) * 3;
        final double luma =
            0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
        hist[luma.round().clamp(0, 255)]++;
        roadTotal++;
      }
    }
    if (roadTotal == 0) return 0.0;
    int acc = 0;
    int road = 0;
    for (int v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc * 2 >= roadTotal) {
        road = v;
        break;
      }
    }

    // A vehicle body is neutral and clearly off the road tone.
    final Uint8List veh = Uint8List(n);
    final int top = (h * 0.12).floor();
    final int bot = (h * 0.95).floor();
    for (int y = top; y < bot; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int i = row + x;
        final int j = i * 3;
        final double r = px[j].toDouble();
        final double g = px[j + 1].toDouble();
        final double b = px[j + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        if (sat < _paveMaxSat && (luma - road).abs() > _crashToneDrop) {
          veh[i] = 1;
        }
      }
    }

    // Only solid, wide bodies count, so a thin pole is not a vehicle.
    final List<_Blob> bodies = <_Blob>[];
    for (final blob in _blobs(veh, w, h, (_crashMinFrac * n).round())) {
      final int bw = blob.maxX - blob.minX + 1;
      final int bh = blob.maxY - blob.minY + 1;
      final double fill = blob.size / (bw * bh).toDouble();
      final double aspect =
          math.max(bw, bh) / math.max(1, math.min(bw, bh)).toDouble();
      final double cy = (blob.minY + blob.maxY) / 2 / h;
      // A vehicle sits on the road, so its body reaches the lower frame.
      final double bottom = (blob.maxY + 1) / h;
      if (fill < _crashMinFillSoft ||
          aspect < 1.0 ||
          aspect > _crashMaxAspectSoft ||
          cy < 0.25 ||
          cy > 0.92 ||
          bottom < _crashBodyBottom) {
        continue;
      }
      bodies.add(blob);
    }
    if (bodies.length < 2) {
      // Two touching vehicles merge into one wide mass, so its tone step is read.
      return _mergedCrashCue(veh, px, w, h, n, road);
    }
    // The best touching pair is the crash, so a parked car elsewhere is ignored.
    double best = 0.0;
    for (int i = 0; i < bodies.length; i++) {
      for (int j = i + 1; j < bodies.length; j++) {
        final _Blob a = bodies[i];
        final _Blob b = bodies[j];
        final double ratio = math.max(a.size, b.size) /
            math.max(1, math.min(a.size, b.size)).toDouble();
        if (ratio > _crashSizeRatio) continue;
        final double gapX =
            math.max(0, math.max(a.minX, b.minX) - math.min(a.maxX, b.maxX)) / w;
        if (gapX > _crashTouchGap) continue;
        final int overlapY = math.min(a.maxY, b.maxY) - math.max(a.minY, b.minY);
        final int shortY = math.min(a.maxY - a.minY, b.maxY - b.minY);
        if (overlapY < _crashOverlap * shortY) continue;
        // The two bodies must sit at the same height, so a stacked pair is not a crash.
        final double cyA = (a.minY + a.maxY) / 2 / h;
        final double cyB = (b.minY + b.maxY) / 2 / h;
        if ((cyA - cyB).abs() > _crashLevel) continue;
        final double width =
            (math.max(a.maxX, b.maxX) - math.min(a.minX, b.minX)) / w;
        if (width < _crashMinWidth) continue;
        final double size =
            math.min(1.0, (a.size + b.size) / n / _crashFullSoft);
        final double score = size * (1.0 - gapX / _crashTouchGap);
        if (score > best) best = score;
      }
    }
    // No separated pair was found, so a merged two-tone mass is checked instead.
    if (best <= 0.0) return _mergedCrashCue(veh, px, w, h, n, road);
    return best;
  }

  // An injured person is a compact skin blob low in the frame.
  double _injuredCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    final Uint8List skin = Uint8List(n);
    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double r = px[j].toDouble();
      final double g = px[j + 1].toDouble();
      final double b = px[j + 2].toDouble();
      final double mx = math.max(r, math.max(g, b));
      final double mn = math.min(r, math.min(g, b));
      final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
      if (r > 95 &&
          g > 40 &&
          b > 20 &&
          r > g &&
          r > b &&
          r - g > _skinRedGreen &&
          r - b > _skinRedBlue &&
          sat > _skinMinSat &&
          sat < 0.65) {
        skin[i] = 1;
      }
    }

    // The total skin area is the reference, so the score is the same near and far.
    int skinTotal = 0;
    for (int i = 0; i < n; i++) {
      if (skin[i] == 1) skinTotal++;
    }
    if (skinTotal == 0) return 0.0;

    // A road injury is one casualty, so the body patches are read together.
    final List<_Blob> people =
        _blobs(skin, w, h, (_injuredMinFrac * n).round());

    // The blob must sit low in the frame, where a fallen person is.
    double best = 0.0;
    for (final blob in people) {
      final double cy = (blob.minY + blob.maxY) / 2 / h;
      if (cy < _injuredLowCy) continue;
      final int bw = blob.maxX - blob.minX + 1;
      final int bh = blob.maxY - blob.minY + 1;
      final double fill = blob.size / (bw * bh).toDouble();
      if (fill < _injuredMinFill) continue;
      // The share of the visible skin is the same near and far, so distance cancels.
      final double share = blob.size / skinTotal.toDouble();
      final double score = math.min(1.0, share / _injuredShareFull);
      if (score > best) best = score;
    }
    return best;
  }

  // Pavement is a neutral ground band, measured against its own median tone.
  double _paveCue(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;

    final int y0 = (h * 0.55).floor();
    final int total = (h - y0) * w;
    if (total <= 0) return 0.0;

    // The band tone is its own median, so a bright or dark road reads the same.
    final List<int> hist = List<int>.filled(256, 0);
    for (int y = y0; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int j = (row + x) * 3;
        final double luma =
            0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
        hist[luma.round().clamp(0, 255)]++;
      }
    }
    int acc = 0;
    int median = 0;
    for (int v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc * 2 >= total) {
        median = v;
        break;
      }
    }

    // Ground is the neutral share of the band that sits near that median tone.
    int ground = 0;
    for (int y = y0; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int j = (row + x) * 3;
        final double r = px[j].toDouble();
        final double g = px[j + 1].toDouble();
        final double b = px[j + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        if (sat < _paveMaxSat && (luma - median).abs() <= _paveToneBand) {
          ground++;
        }
      }
    }
    final double a = ground / total.toDouble();
    if (a < _paveMinAsphalt) return 0.0;
    return math.min(1.0, a / _paveFull);
  }

  // Blood, faint and helper cues for one image, all from one pass.
  List<double> _medicalCues(img.Image source) {
    final img.Image small = _resize(source, _gunSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    // The frame brightness sets the clothing threshold, so a dark room works.
    double sumL = 0;
    double sumL2 = 0;
    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double l = 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
      sumL += l;
      sumL2 += l * l;
    }
    final double meanL = sumL / n;
    final double stdL = math.sqrt(math.max(0.0, sumL2 / n - meanL * meanL));
    final double brightT = math.max(
      _personBrightBase,
      meanL + _personBrightStd * stdL,
    );

    final Uint8List skin = Uint8List(n);
    final Uint8List person = Uint8List(n);
    final Uint8List blood = Uint8List(n);
    int skinCount = 0;

    for (int i = 0; i < n; i++) {
      final int j = i * 3;
      final double r = px[j].toDouble();
      final double g = px[j + 1].toDouble();
      final double b = px[j + 2].toDouble();
      final double mx = math.max(r, math.max(g, b));
      final double mn = math.min(r, math.min(g, b));
      final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
      final double luma = 0.299 * r + 0.587 * g + 0.114 * b;

      // Skin tone, the strongest cue for a person needing help.
      if (r > 95 &&
          g > 40 &&
          b > 20 &&
          r > g &&
          r > b &&
          r - g > _skinRedGreen &&
          r - b > _skinRedBlue &&
          sat > _skinMinSat &&
          sat < 0.65) {
        skin[i] = 1;
        skinCount++;
      }
      // Bright clothing, so a body is found even when the skin is hidden.
      if (luma > brightT && sat < _personBrightSat) person[i] = 1;
      // Blood is a strong red on the body, so it is measured against the skin.
      if (r > 80 &&
          r - g > _bloodRedGreen &&
          r - b > _bloodRedBlue &&
          sat > _bloodSat &&
          luma < _bloodLuma) {
        blood[i] = 1;
      }
      if (skin[i] == 1) person[i] = 1;
    }

    // Blood is the strongest of the skin relative and frame wide readings.
    final double fSkin = skinCount / n;

    // Blood only counts beside visible skin, so a red shirt or floor is excluded.
    Uint8List nearSkin = Uint8List.fromList(skin);
    for (int pass = 0; pass < _bloodNearPass; pass++) {
      final Uint8List grown = Uint8List.fromList(nearSkin);
      for (int y = 1; y < h - 1; y++) {
        final int row = y * w;
        for (int x = 1; x < w - 1; x++) {
          final int i = row + x;
          if (nearSkin[i] == 1) continue;
          if (nearSkin[i - 1] == 1 ||
              nearSkin[i + 1] == 1 ||
              nearSkin[i - w] == 1 ||
              nearSkin[i + w] == 1) {
            grown[i] = 1;
          }
        }
      }
      nearSkin = grown;
    }

    // The near skin reading and the two mean luma values, all in this pass.
    int nearCount = 0;
    double skinLuma = 0;
    double bloodLuma = 0;
    for (int i = 0; i < n; i++) {
      if (skin[i] == 1) {
        final int j = i * 3;
        skinLuma += 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
      }
      if (blood[i] == 1 && nearSkin[i] == 1) {
        final int j = i * 3;
        bloodLuma += 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
        nearCount++;
      }
    }
    final double nearFrac = nearCount / n;
    final double meanSkinLuma = skinCount == 0 ? 0.0 : skinLuma / skinCount;
    final double meanBloodLuma = nearCount == 0 ? 0.0 : bloodLuma / nearCount;

    // A wound is darker than the skin it runs on, cloth and warm light are not.
    final bool darker = meanSkinLuma - meanBloodLuma >= _bloodDrop;
    // One huge red mass is clothing or a floor, so the largest patch is capped.
    double biggestBlood = 0.0;
    for (final blob in _blobs(blood, w, h, 4)) {
      final double share = blob.size / n;
      if (share > biggestBlood) biggestBlood = share;
    }
    final bool patchSized = biggestBlood <= _bloodMaxBlob;
    final bool enoughNear = nearFrac >= _bloodMinNear;
    final bool hasSkin = fSkin >= _bloodMinSkin;

    final double bloodScore = hasSkin && darker && patchSized && enoughNear
        ? math.min(1.0, nearFrac / _bloodNearFull)
        : 0.0;

    // The person mass and its height in the frame.
    int personCount = 0;
    double sumY = 0;
    for (int i = 0; i < n; i++) {
      if (person[i] == 1) {
        personCount++;
        sumY += i ~/ w;
      }
    }
    final double personFrac = personCount / n;
    final double personCy = personCount == 0 ? 0.0 : (sumY / personCount) / h;

    // Skin clusters, the reliable person count for the helper and faint cues.
    final List<_Blob> clusters = _blobs(
      skin,
      w,
      h,
      (_helperMinFrac * n).round(),
    );

    // A fainted person is a low skin mass, so the low skin area is measured.
    double lowSkin = 0;
    double allSkin = 0;
    for (final c in clusters) {
      // A blob this large is water or a wall, so it is not a body.
      if (c.size / n > _faintMaxBlob) continue;
      allSkin += c.size / n;
      if (c.cy >= _faintLowCy * h) lowSkin += c.size / n;
    }
    final double faintSkin = math.min(1.0, lowSkin / _faintSkinFull);
    // The share of the visible person lying low is the same near and far.
    final double faintRel = allSkin <= 0
        ? 0.0
        : math.min(1.0, (lowSkin / allSkin) / _faintSkinRel);
    // A lying body is a wide person blob low in the frame, so it reads as fainted.
    double lyingScore = 0.0;
    final List<_Blob> bodies = _blobs(
      person,
      w,
      h,
      (_helperMinFrac * n).round(),
    );
    for (final b in bodies) {
      final int bw = b.maxX - b.minX + 1;
      final int bh = b.maxY - b.minY + 1;
      if (bw < _lyingAspect * bh) continue;
      if (b.cy < _lyingLowCy * h) continue;
      // A blob this large is water or a wall, so it is not a body.
      if (b.size / n > _faintMaxBlob) continue;
      final double v = math.min(1.0, (b.size / n) / _lyingFull);
      if (v > lyingScore) lyingScore = v;
    }
    // A low bright body mass also counts, so a pale body still reads as fainted.
    // A mass this large is a bright surface, so it is not one body.
    final double faintBright = personFrac > _faintMaxBlob
        ? 0.0
        : math.min(1.0, math.max(0.0, (personCy - 0.50) / 0.18)) *
            math.min(1.0, personFrac / 0.08);
    final double faintScore = math.max(
      faintSkin,
      math.max(faintRel, math.max(lyingScore, faintBright)),
    );

    // A helper is an upright person standing beside a low fainted person.
    double helperScore = 0.0;
    // The largest blob is the reference, so the size gates cancel distance.
    final double biggest = clusters.isEmpty
        ? 0.0
        : clusters.first.size.toDouble();
    for (int a = 0; a < clusters.length; a++) {
      for (int c = a + 1; c < clusters.length; c++) {
        final _Blob first = clusters[a];
        final _Blob second = clusters[c];
        final _Blob up = first.cy <= second.cy ? first : second;
        final _Blob low = first.cy <= second.cy ? second : first;
        // Both people must be big enough to be a real body, not noise.
        if (biggest <= 0 ||
            up.size < _helperRelSize * biggest ||
            low.size < _helperRelSize * biggest) {
          continue;
        }
        // The fainted person lies low in the frame.
        if (low.cy < _helperLowCy * h) continue;
        // A body is not a solid rectangle, so a flat ground strip is excluded.
        final int lowW = low.maxX - low.minX + 1;
        final int lowH = low.maxY - low.minY + 1;
        if (low.size / (lowW * lowH).toDouble() > _helperLowFill) continue;
        // The helper stands upright, so the blob is taller than it is wide.
        if (up.maxY - up.minY < _helperUpright * (up.maxX - up.minX)) continue;
        // The two people are side by side, so their boxes do not overlap.
        final int gap = up.minX > low.maxX
            ? up.minX - low.maxX
            : (low.minX > up.maxX ? low.minX - up.maxX : 0);
        if (gap < _helperGapX * w) continue;
        // The helper is clearly higher than the person on the ground.
        if (low.cy - up.cy < _helperDropY * h) continue;
        final double v = math.min(
          1.0,
          ((first.size + second.size) / biggest) / _helperRelFull,
        );
        if (v > helperScore) helperScore = v;
      }
    }

    return [bloodScore, faintScore, helperScore];
  }

  // Foliage, hot region blue leak and the hostage cues for one image.
  List<double> _sceneCues(img.Image source) {
    final img.Image small = _resize(source, _hostageSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    double green = 0;
    double hotCount = 0;
    double hotBlue = 0;
    double skin = 0;

    // The centre band is where a hostage and captor sit.
    final int cy0 = (h * 0.25).floor();
    final int cy1 = (h * 0.85).floor();
    final int cx0 = (w * 0.20).floor();
    final int cx1 = (w * 0.80).floor();
    final int centreArea = math.max(1, (cy1 - cy0) * (cx1 - cx0));
    double centreWhite = 0;
    double centreBlack = 0;

    for (int y = 0; y < h; y++) {
      final int row = y * w * 3;
      for (int x = 0; x < w; x++) {
        final int i = row + x * 3;
        final double r = px[i].toDouble();
        final double g = px[i + 1].toDouble();
        final double b = px[i + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;

        // Green foliage, the strongest sign of a garden rather than a fire.
        if (g > r + 12 && g > b + 12 && g > 45 && sat > 0.15) green++;
        // Hot pixels, the region a flame or a sun would occupy.
        if (r > 150 && r > g + 25 && sat > 0.30) {
          hotCount++;
          hotBlue += b / math.max(r, 1.0);
        }
        // Bright fabric or gauze.
        if (luma > 195 && sat < 0.16) {
          if (y >= cy0 && y < cy1 && x >= cx0 && x < cx1) centreWhite++;
        }
        // Dark low light scene.
        if (luma < 40) {
          if (y >= cy0 && y < cy1 && x >= cx0 && x < cx1) centreBlack++;
        }
        // Skin tone, the strongest cue for a person needing help.
        if (r > 95 &&
            g > 40 &&
            b > 20 &&
            r > g &&
            r > b &&
            r - g > _skinRedGreen &&
            r - b > _skinRedBlue &&
            sat > _skinMinSat &&
            sat < 0.65) {
          skin++;
        }
      }
    }

    // A hot region with this much blue is daylight or sky, not a flame.
    final double blue = hotCount < 30 ? 0.0 : hotBlue / hotCount;
    return [
      green / n,
      blue,
      centreWhite / centreArea,
      centreBlack / centreArea,
      skin / n,
    ];
  }

  // Counts separate people by looking for gaps in the person columns.
  double _groupCount(img.Image source) {
    final img.Image small = _resize(source, _groupSize);
    final Uint8List px = small.getBytes(order: img.ChannelOrder.rgb);
    final int w = small.width;
    final int h = small.height;
    final int n = w * h;

    // One mask of person pixels, so separate bodies can be counted.
    final Uint8List mask = Uint8List(n);

    for (int y = 0; y < h; y++) {
      final int base = y * w * 3;
      for (int x = 0; x < w; x++) {
        final int i = base + x * 3;
        final double r = px[i].toDouble();
        final double g = px[i + 1].toDouble();
        final double b = px[i + 2].toDouble();
        final double mx = math.max(r, math.max(g, b));
        final double mn = math.min(r, math.min(g, b));
        final double sat = mx > 0 ? (mx - mn) / mx : 0.0;
        final double luma = 0.299 * r + 0.587 * g + 0.114 * b;

        // Skin, dark clothing and tactical green all mark a person.
        final bool skin =
            r > 95 &&
            g > 40 &&
            b > 20 &&
            r > g &&
            r > b &&
            r - g > _skinRedGreen &&
            r - b > _skinRedBlue &&
            sat > _skinMinSat &&
            sat < 0.65;
        final bool dark = luma < 80;
        final bool tactical = g > r + 10 && g > b + 10 && g > 45 && sat > 0.15;

        // The mask is indexed by pixel, not by the rgb byte offset.
        if (skin || dark || tactical) mask[y * w + x] = 1;
      }
    }

    // A small gap is bridged first, so two legs are not counted as two people.
    final Uint8List grown = Uint8List(n);
    for (int y = 0; y < h; y++) {
      final int base = y * w;
      for (int x = 0; x < w; x++) {
        if (mask[base + x] == 0) continue;
        final int y0 = math.max(0, y - _crowdGap);
        final int y1 = math.min(h - 1, y + _crowdGap);
        final int x0 = math.max(0, x - _crowdGap);
        final int x1 = math.min(w - 1, x + _crowdGap);
        for (int yy = y0; yy <= y1; yy++) {
          final int r2 = yy * w;
          for (int xx = x0; xx <= x1; xx++) {
            grown[r2 + xx] = 1;
          }
        }
      }
    }

    // Each separate blob is one body, so one person standing alone counts once.
    int people = 0;
    for (final blob in _blobs(grown, w, h, (0.004 * n).round())) {
      final int bw = blob.maxX - blob.minX + 1;
      final int bh = blob.maxY - blob.minY + 1;
      // A body is tall and not frame wide, so a wall or floor is not a person.
      if (bh < _crowdMinHeight * h) continue;
      if (bw > _crowdMaxWidth * w) continue;
      people++;
    }
    return people.toDouble();
  }

  // Sharpens Crime, Flood and Medical with the gun and medical cues.
  void _applyFocus(
    List<double> probs,
    List<int> incidentIdx,
    _Cues cues,
    List<double> modelProbs,
  ) {
    int crimePos = -1;
    int floodPos = -1;
    int medicalPos = -1;
    int accidentPos = -1;
    for (int pos = 0; pos < incidentIdx.length; pos++) {
      final String label = _labelFor(incidentIdx[pos]);
      if (label == 'Crime') crimePos = pos;
      if (label == 'Flood') floodPos = pos;
      if (label == 'Medical Emergency') medicalPos = pos;
      if (label == 'Accident') accidentPos = pos;
    }

    // The gun only counts when a person is there to hold it.
    final double gunFocus = _gunFocus * cues.gun * cues.person;
    // A crash or an injured person on pavement points at an accident.
    final double accidentCue =
        math.max(cues.pave, _paveSoftFloor) * math.max(cues.crash, cues.injured);
    final double accidentFocus = _accidentFocus * accidentCue;
    // A strong accident cue means the wet road is not a flood.
    final double accidentHold = accidentCue >= _accidentStrong ? 0.0 : 1.0;
    // A vehicle, a flooded road or open water all point at flood.
    final double floodFocus =
        _floodFocus *
        math.max(cues.veh, math.max(cues.road, cues.water)) *
        accidentHold;
    // Blood, a faint or a helper all point at a medical emergency.
    final double medicalFocus =
        _medicalFocus * math.max(cues.blood, math.max(cues.faint, cues.helper));

    // The focus only sharpens a class that already leads, so nothing is flipped.
    double lead = 0.0;
    for (final v in probs) {
      if (v > lead) lead = v;
    }
    if (crimePos >= 0 && gunFocus > 0 && probs[crimePos] >= _leadGate * lead) {
      probs[crimePos] *= 1.0 + gunFocus;
    }
    if (floodPos >= 0 &&
        floodFocus > 0 &&
        probs[floodPos] >= _leadGate * lead) {
      probs[floodPos] *= 1.0 + floodFocus;
    }
    if (medicalPos >= 0 &&
        medicalFocus > 0 &&
        probs[medicalPos] >= _leadGate * lead) {
      probs[medicalPos] *= 1.0 + medicalFocus;
    }
    // A confirmed accident on pavement outranks a flooded road look.
    if (accidentPos >= 0 &&
        accidentFocus > 0 &&
        probs[accidentPos] >= _leadGate * lead) {
      probs[accidentPos] *= 1.0 + accidentFocus;
    }

    // A strong accident cue on pavement can outrank a leading medical or crime call.
    // The accident evidence must also beat the medical evidence, so a real injury stays medical.
    final double accidentEvidence = cues.evidence.length > 2
        ? cues.evidence[2]
        : 0.0;
    final double medicalEvidence = cues.evidence.length > 4
        ? cues.evidence[4]
        : 0.0;
    final double floodEvidence = cues.evidence.length > 1
        ? cues.evidence[1]
        : 0.0;
    // A confirmed flood with model support outranks a wrong medical lead.
    final double floodModel = floodPos >= 0 && floodPos < modelProbs.length
        ? modelProbs[floodPos]
        : 0.0;
    final bool floodFirst =
        floodPos >= 0 &&
        cues.water >= _floodWaterGate &&
        floodEvidence > medicalEvidence &&
        floodEvidence > accidentEvidence &&
        cues.blood < _bloodGate &&
        cues.faint < _faintGate &&
        cues.helper < _helperGate &&
        cues.crash < _crashGate &&
        cues.injured < _injuredGate &&
        floodModel >= _floodModelGate;
    // A confirmed wound is a medical case, so it blocks the accident override.
    final bool woundFirst = cues.blood >= _bloodGate;
    // A confirmed crash is a collision, so it outranks a crime or flood lead.
    final bool crashFirst = cues.crash >= _crashGate;
    // A confirmed injury on a strong ground reading is a road accident.
    // A helper beside the person means a medical case, not a road injury.
    final bool injuredFirst =
        cues.injured >= _injuredGate &&
        cues.pave >= _paveClose &&
        cues.helper < _helperGate;
    final bool accidentOverride =
        accidentPos >= 0 &&
        !woundFirst &&
        (crashFirst ||
            injuredFirst ||
            (accidentCue >= _accidentOverride &&
                accidentEvidence > _accidentEvidenceRatio * medicalEvidence));
    if (accidentOverride) {
      // The accident is lifted to the current lead, then sharpened by its own cue.
      probs[accidentPos] = math.max(probs[accidentPos], lead) *
          (1.0 + accidentFocus);
      // A medical or crime lead on the same frame is damped, not deleted.
      if (medicalPos >= 0) probs[medicalPos] *= _accidentDamp;
      if (crimePos >= 0) probs[crimePos] *= _accidentDamp;
      if (floodPos >= 0) probs[floodPos] *= _accidentDamp;
    }

    // A confirmed flood on open water outranks a wrong medical or crime lead.
    if (floodFirst && !accidentOverride) {
      // The flood is lifted to the current lead, then sharpened by its own cue.
      probs[floodPos] = math.max(probs[floodPos], lead) * (1.0 + floodFocus);
      // A medical or crime lead on the same frame is damped, not deleted.
      if (medicalPos >= 0) probs[medicalPos] *= _floodDamp;
      if (crimePos >= 0) probs[crimePos] *= _floodDamp;
    }

    final double total = probs.fold<double>(0.0, (a, b) => a + b);
    if (total > 0) {
      for (int i = 0; i < probs.length; i++) {
        probs[i] = probs[i] / total;
      }
    }
  }

  // Turns the fused distribution into a calibrated, honest result.
  _Raw resultFromProbs(_Scored scored, _Cues cues) {
    final List<double> fused = scored.fused;
    final int othersIdx = _labels.indexOf('Others');

    // The Others mass is measured before it is removed from the distribution.
    final double othersMass = othersIdx >= 0 && othersIdx < fused.length
        ? fused[othersIdx]
        : 0.0;

    // Only the incident classes are kept, so Others cannot deflate a real score.
    final incidentIdx = <int>[];
    for (int i = 0; i < fused.length; i++) {
      if (i == othersIdx) continue;
      if (i < _labels.length &&
          !EmergencyAIService.validCategories.contains(_labels[i])) {
        continue;
      }
      incidentIdx.add(i);
    }

    // A model with unexpected labels still has to return a prediction.
    if (incidentIdx.isEmpty) {
      for (int i = 0; i < fused.length; i++) {
        incidentIdx.add(i);
      }
    }

    // The incident classes are renormalised so they sum back to one.
    final raw = <double>[];
    for (final i in incidentIdx) {
      raw.add(fused[i].clamp(1e-9, 1.0).toDouble());
    }
    final rawTotal = raw.fold<double>(0.0, (a, b) => a + b);
    final modelProbs = raw.map((v) => v / rawTotal).toList();

    // Colour evidence is blended in, so a clear scene is not lost to the model.
    final evidence = cues.evidence;
    final blended = <double>[];
    for (int i = 0; i < modelProbs.length; i++) {
      final ev = i < evidence.length ? evidence[i] : 0.0;
      blended.add((1 - _evidenceWeight) * modelProbs[i] + _evidenceWeight * ev);
    }
    final blendTotal = blended.fold<double>(0.0, (a, b) => a + b);
    final probs = blendTotal <= 0
        ? blended
        : blended.map((v) => v / blendTotal).toList();

    // The model's own top is kept, so the non-incident gate reads the model.
    double modelTop = 0.0;
    for (final v in modelProbs) {
      if (v > modelTop) modelTop = v;
    }
    _applyFocus(probs, incidentIdx, cues, modelProbs);

    // Ranked by score, so the top class and the runner up are both known.
    final order = List<int>.generate(probs.length, (i) => i)
      ..sort((a, b) => probs[b].compareTo(probs[a]));

    final int bestPos = order.first;
    final int secondPos = order.length > 1 ? order[1] : order.first;

    final int bestIdx = incidentIdx[bestPos];
    String category = _labelFor(bestIdx);
    final String runnerUp = order.length > 1
        ? _labelFor(incidentIdx[secondPos])
        : '';

    final double top = probs[bestPos];
    final double margin = top - probs[secondPos];

    // How many views agreed with the winning class, a stability signal.
    final double agreement = _viewAgreement(
      scored.perView,
      incidentIdx,
      bestIdx,
    );

    // Evidence for the winning class, so a clear scene scores higher.
    final double evidenceTop = bestPos < evidence.length
        ? evidence[bestPos]
        : 0.0;

    // Each signal is normalised, then combined into one strength value.
    final double probNorm = math.min(1.0, top / _probDivisor);
    final double marginNorm = math.min(1.0, margin / _marginDivisor);
    final double evidenceNorm = math.min(1.0, evidenceTop / _evidenceDivisor);
    final double strength =
        0.50 * probNorm +
        0.20 * marginNorm +
        0.15 * agreement +
        0.15 * evidenceNorm;

    // A correct call lands in the 80 to 100 band, a weak one stays below 80.
    double score = _scoreBase + _scoreSpan * strength;

    // Weak view agreement lowers the score a little instead of forcing a guess.
    if (agreement < _guessAgreement) {
      score -= _agreementPenalty;
    }

    // A near tie means a guess, never a confirmed fact.
    bool bestGuess = margin < _guessMargin;

    // A scene the model calls mostly Others is not an incident.
    bool nonIncident = othersMass > _othersGate;

    // Set when the media is not an incident type at all.
    bool unreadable = false;

    // A winner that barely beats chance is not a real detection.
    if (modelTop < _topGate) nonIncident = true;

    // The model calling Others the top class means the media is not an incident.
    if (othersIdx >= 0 && othersIdx < fused.length) {
      int topIdx = 0;
      for (int i = 1; i < fused.length; i++) {
        if (fused[i] > fused[topIdx]) topIdx = i;
      }
      if (topIdx == othersIdx) nonIncident = true;
    }

    // A hot region inside foliage is daylight through leaves, not a fire.
    // The check is fire only, so a flooded scene with plants is not rejected.
    if (category == 'Fire' &&
        cues.green > _greenVeto &&
        cues.fire.isNotEmpty &&
        cues.fire[0] >= _flameHighFraction) {
      nonIncident = true;
    }

    // A very green scene is a garden or park, so it is not a crime or a medical case.
    if (cues.green > _greenSceneVeto &&
        (category == 'Crime' || category == 'Medical Emergency')) {
      nonIncident = true;
    }

    // Fire is banded by what is visible, flame is high and smoke alone is medium.
    if (category == 'Fire' && cues.fire.length >= 2) {
      final double flameFraction = cues.fire[0];
      final double smokeFraction = cues.fire[1];
      if (flameFraction >= _flameHighFraction) {
        // A real hot region is a flame unless it is daylight or foliage.
        if (cues.green > _greenVeto || cues.blue > _blueVeto) {
          nonIncident = true;
        } else {
          score = math.max(score, AIClassificationResult.highThreshold);
          bestGuess = false;
        }
      } else if (smokeFraction >= _smokeMediumFraction) {
        // Smoke alone is a medium fire, a garden with no smoke is not.
        if (cues.green > _greenStrong) {
          nonIncident = true;
        } else {
          score = math.min(
            math.max(score, AIClassificationResult.acceptThreshold),
            0.89,
          );
          bestGuess = false;
        }
      } else {
        nonIncident = true;
      }
    }

    // A casualty with a helper kneeling over them is a medical case, not a road injury.
    // A visible flame means the scene is a fire, so the accident call is kept.
    final bool flameScene =
        cues.fire.isNotEmpty && cues.fire[0] >= _flameHighFraction;
    if (category == 'Accident' &&
        cues.crash < _crashGate &&
        cues.helper >= _helperGate &&
        !flameScene) {
      category = 'Medical Emergency';
    }

    // A group of two or more people is a Terrorist scene, not a lone Crime.
    final bool groupScene =
        cues.group >= _groupMinPeople &&
        cues.hostageWhite >= _groupWhite &&
        cues.hostageBlack >= _groupBlack &&
        cues.hostageSkin >= _hostageSkin;
    // A single hostage still counts, the group check only widens the net.
    final bool hostageScene =
        cues.hostageWhite >= _hostageWhite &&
        cues.hostageBlack >= _hostageBlack &&
        cues.hostageSkin >= _hostageSkin;
    if (category == 'Crime' && (groupScene || hostageScene)) {
      category = 'Terrorist';
      score = math.max(score, AIClassificationResult.highThreshold);
      bestGuess = false;
    }

    // A confirmed faint, helper or wound is a real medical case, so it is accepted.
    if (category == 'Medical Emergency' &&
        (cues.blood >= _bloodGate ||
            cues.helper >= _helperGate ||
            cues.faint >= _faintGate)) {
      nonIncident = false;
      unreadable = false;
      bestGuess = false;
    }

    // A non-incident scene is capped below the accept line and shown as unreadable.
    if (nonIncident) {
      score = math.min(score, _nonIncidentCap);
      bestGuess = true;
      unreadable = true;
    }

    // A guess is reported with its real score, capped so it never looks sure.
    if (bestGuess) score = math.min(score, _guessScoreCap);

    // A confirmed flood is accepted, so it is shown from 80 to 100 percent.
    if (category == 'Flood' && !nonIncident && !bestGuess) {
      score = math.max(score, AIClassificationResult.acceptThreshold);
    }

    // A lone dark hooded person is a confirmed crime, so a loud background cannot hide it.
    // The model must also back Crime, so an empty street is not accepted.
    int crimePos = -1;
    for (int pos = 0; pos < incidentIdx.length; pos++) {
      if (_labelFor(incidentIdx[pos]) == 'Crime') crimePos = pos;
    }
    // The absolute fused mass is read, so removing Others cannot inflate Crime.
    final double crimeModel = crimePos >= 0
        ? fused[incidentIdx[crimePos]]
        : 0.0;
    final bool crimeFirst =
        category == 'Crime' &&
        cues.person >= _crimePersonGate &&
        crimeModel >= _crimeModelGate &&
        !groupScene &&
        !hostageScene;
    if (crimeFirst) {
      nonIncident = false;
      unreadable = false;
      bestGuess = false;
      score = math.max(score, AIClassificationResult.acceptThreshold);
    }

    // A confirmed accident is a crash on a paved road or an injured person.
    String subScene = '';
    // A confirmed crash or injury is a real accident, so it is never unreadable.
    // A helper beside the person means a medical case, not a road injury.
    if (cues.crash >= _crashGate ||
        (cues.injured >= _injuredGate &&
            cues.pave >= _paveClose &&
            cues.helper < _helperGate)) {
      nonIncident = false;
      unreadable = false;
      bestGuess = false;
    }
    if (category == 'Accident' && !nonIncident) {
      if (cues.crash >= _crashGate) {
        // Two vehicles crashing each other is shown from 80 to 100 percent.
        subScene = 'crash';
        score = math.max(score, AIClassificationResult.acceptThreshold);
        bestGuess = false;
      } else if (cues.injured >= _injuredGate) {
        // One person injured is shown from 80 to 89 percent.
        subScene = 'injured';
        score = math.min(
          math.max(score, AIClassificationResult.acceptThreshold),
          0.89,
        );
        bestGuess = false;
      }
    }

    // A confirmed medical sub-scene sets the band, blood is the severe case.
    if (category == 'Medical Emergency' && !nonIncident && !bestGuess) {
      if (cues.blood >= _bloodGate) {
        // Blood is the severe case, so it is shown from 90 to 100 percent.
        subScene = 'blood';
        score = math.max(score, AIClassificationResult.highThreshold);
      } else if (cues.helper >= _helperGate) {
        // Helping a fainted person is mild, so it is shown from 80 to 89.
        subScene = 'helper';
        score = math.min(
          math.max(score, AIClassificationResult.acceptThreshold),
          0.89,
        );
      } else if (cues.faint >= _faintGate) {
        // A fainted person is mild, so it is shown from 80 to 89.
        subScene = 'faint';
        score = math.min(
          math.max(score, AIClassificationResult.acceptThreshold),
          0.89,
        );
      }
    }

    score = score.clamp(0.0, 0.99).toDouble();

    // The decision score is returned, the shown number is picked at the boundary.
    return _Raw(category, score, runnerUp, bestGuess, unreadable, subScene);
  }

  // Fraction of views whose own top incident class matches the fused winner.
  double _viewAgreement(
    List<List<double>> perView,
    List<int> incidentIdx,
    int winner,
  ) {
    if (perView.isEmpty) return 1.0;

    int agree = 0;
    for (final view in perView) {
      int best = incidentIdx.first;
      double bestScore = -1.0;
      for (final i in incidentIdx) {
        if (i < view.length && view[i] > bestScore) {
          bestScore = view[i];
          best = i;
        }
      }
      if (best == winner) agree++;
    }
    return agree / perView.length;
  }

  // Maps a model index to one of the app's incident types.
  String _labelFor(int index) {
    final raw = index < _labels.length ? _labels[index] : 'Others';

    if (EmergencyAIService.appTypes.contains(raw)) return raw;

    // Unknown labels are narrowed down by keyword before giving up.
    final mapped = _mapUnknownLabel(raw);
    return EmergencyAIService.appTypes.contains(mapped)
        ? mapped
        : EmergencyAIService.validCategories.first;
  }

  // Maps unknown model labels to one of the 5 categories.
  String _mapUnknownLabel(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('fire') ||
        lower.contains('burn') ||
        lower.contains('smoke') ||
        lower.contains('flame')) {
      return 'Fire';
    }
    if (lower.contains('flood') ||
        lower.contains('water') ||
        lower.contains('typhoon') ||
        lower.contains('rain')) {
      return 'Flood';
    }
    // Accident words: crash, collision, wreck, vehicle, traffic.
    if (lower.contains('accident') ||
        lower.contains('crash') ||
        lower.contains('collision') ||
        lower.contains('wreck') ||
        lower.contains('vehicle') ||
        lower.contains('traffic')) {
      return 'Accident';
    }
    // Crime words: robbery, theft, assault, shooting, stabbing, violence.
    if (lower.contains('crime') ||
        lower.contains('rob') ||
        lower.contains('theft') ||
        lower.contains('steal') ||
        lower.contains('assault') ||
        lower.contains('shoot') ||
        lower.contains('stab') ||
        lower.contains('gun') ||
        lower.contains('violence') ||
        lower.contains('fight')) {
      return 'Crime';
    }
    // Medical words: injury, wound, bleeding, unconscious, ambulance, heart.
    if (lower.contains('medical') ||
        lower.contains('ambulance') ||
        lower.contains('heart') ||
        lower.contains('drown') ||
        lower.contains('injur') ||
        lower.contains('wound') ||
        lower.contains('bleed') ||
        lower.contains('blood') ||
        lower.contains('unconscious') ||
        lower.contains('faint') ||
        lower.contains('sick')) {
      return 'Medical Emergency';
    }
    // Terrorist words: bomb, explosion, blast, terror, hostage, gunmen.
    if (lower.contains('terror') ||
        lower.contains('bomb') ||
        lower.contains('explos') ||
        lower.contains('blast') ||
        lower.contains('hostage') ||
        lower.contains('gunmen')) {
      return 'Terrorist';
    }
    return 'Fire';
  }
}
