import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Error: $e.code\nError Message: $e.message');
  }
  runApp(const MaterialApp(home: PoseDetectorView()));
}

class PoseDetectorView extends StatefulWidget {
  const PoseDetectorView({super.key});

  @override
  State<PoseDetectorView> createState() => _PoseDetectorViewState();
}

class _PoseDetectorViewState extends State<PoseDetectorView> {
  final PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions());
  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  CameraController? _controller;
  
  // DEBUG LOGGING STATE
  final List<String> _logs = [];
  String _realTimeStats = "Initializing...";

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    _canProcess = false;
    _poseDetector.close();
    _controller?.dispose();
    super.dispose();
  }

  /// Adds a message to the scrolling log at the bottom
  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add("${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second} - $message");
      if (_logs.length > 15) {
        _logs.removeAt(0); // Keep list clean
      }
    });
  }

  /// Updates the fixed stats display at the top
  void _updateStats(String stats) {
    if (!mounted) return;
    setState(() {
      _realTimeStats = stats;
    });
  }

  void _initializeCamera() async {
    _log("Searching for cameras...");
    if (cameras.isEmpty) {
      _log("No cameras found!");
      return;
    }

    // Usually 0 is back, 1 is front. Let's try to find a front camera.
    var cameraIndex = 0;
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].lensDirection == CameraLensDirection.front) {
        cameraIndex = i;
        break;
      }
    }
    
    _controller = CameraController(
      cameras[cameraIndex],
      ResolutionPreset.medium, // Lower resolution is faster for processing
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 // Android expects NV21
          : ImageFormatGroup.bgra8888, // iOS expects BGRA
    );

    try {
      await _controller?.initialize();
      _log("Camera initialized.");
      _startLiveFeed();
    } catch (e) {
      _log("Camera error: $e");
    }
  }

  void _startLiveFeed() {
    _controller?.startImageStream(_processImage);
    _log("Live feed started.");
  }

  Future<void> _processImage(CameraImage image) async {
    if (!_canProcess || _isBusy) return;
    _isBusy = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        // _log("Failed to convert image."); // Commented out to avoid spamming logs
        _isBusy = false;
        return;
      }

      final poses = await _poseDetector.processImage(inputImage);

      // --- DEBUGGING LOGIC START ---
      String stats = "Img: ${image.width}x${image.height}\n"
          "Poses detected: ${poses.length}";

      if (poses.isNotEmpty) {
        final pose = poses.first;
        // Log the Nose coordinates as a sanity check
        final nose = pose.landmarks[PoseLandmarkType.nose];
        if (nose != null) {
          stats += "\nNose: (${nose.x.toStringAsFixed(1)}, ${nose.y.toStringAsFixed(1)})";
          stats += "\nConfidence: ${(nose.likelihood * 100).toStringAsFixed(1)}%";
        }
        
        // Check if feet are visible
        final leftFoot = pose.landmarks[PoseLandmarkType.leftFootIndex];
        final rightFoot = pose.landmarks[PoseLandmarkType.rightFootIndex];
        stats += "\nFeet visible: ${leftFoot != null ? 'L' : '-'}/${rightFoot != null ? 'R' : '-'}";
      }
      _updateStats(stats);
      // --- DEBUGGING LOGIC END ---

      if (inputImage.metadata?.size != null &&
          inputImage.metadata?.rotation != null) {
        final painter = PosePainter(
          poses,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
          _controller!.description.lensDirection,
        );
        _customPaint = CustomPaint(painter: painter);
      } else {
        _customPaint = null;
      }
    } catch (e) {
      _log("Error processing image: $e");
    }

    _isBusy = false;
    if (mounted) {
      setState(() {});
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;

    // get camera rotation
    final camera = _controller!.description;
    final sensorOrientation = camera.sensorOrientation;
    
    InputImageRotation rotation = InputImageRotation.rotation0deg;
    if (Platform.isAndroid) {
       var rotationCompensation = _orientations[_controller!.value.deviceOrientation];
       if (rotationCompensation == null) return null;
       if (camera.lensDirection == CameraLensDirection.front) {
         // front-facing
         rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
       } else {
         // back-facing
         rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
       }
       rotation = InputImageRotationValue.fromRawValue(rotationCompensation) ?? InputImageRotation.rotation0deg;
    } else if (Platform.isIOS) {
       rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
    }

    // Normalize format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null; 

    final allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }
  
  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
          body: Center(child: Text("Initializing Camera...\n${_logs.join('\n')}")));
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          if (_customPaint != null) _customPaint!,
          
          // --- DEBUG OVERLAY START ---
          
          // Top Right: Real-time Stats
          Positioned(
            top: 40,
            right: 10,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _realTimeStats,
                style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontFamily: 'monospace'),
              ),
            ),
          ),

          // Bottom: Event Log
          Positioned(
            bottom: 20,
            left: 10,
            right: 10,
            height: 150,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("System Logs:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  const Divider(color: Colors.white30, height: 8),
                  Expanded(
                    child: ListView.builder(
                      reverse: true, 
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Text(
                          _logs[_logs.length - 1 - index],
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // --- DEBUG OVERLAY END ---
        ],
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size absoluteImageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;

  PosePainter(this.poses, this.absoluteImageSize, this.rotation, this.cameraLensDirection);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..color = Colors.green;

    final landmarkPaint = Paint()
      ..style = PaintingStyle.fill
      ..strokeWidth = 5.0
      ..color = Colors.red;

    for (final pose in poses) {
      // Draw all landmarks
      pose.landmarks.forEach((_, landmark) {
        canvas.drawCircle(
          Offset(
            translateX(landmark.x, size, absoluteImageSize, rotation, cameraLensDirection),
            translateY(landmark.y, size, absoluteImageSize, rotation, cameraLensDirection),
          ),
          4,
          landmarkPaint,
        );
      });

      void paintLine(PoseLandmarkType type1, PoseLandmarkType type2) {
        final PoseLandmark? joint1 = pose.landmarks[type1];
        final PoseLandmark? joint2 = pose.landmarks[type2];
        if (joint1 != null && joint2 != null) {
          canvas.drawLine(
              Offset(
                  translateX(joint1.x, size, absoluteImageSize, rotation, cameraLensDirection),
                  translateY(joint1.y, size, absoluteImageSize, rotation, cameraLensDirection)),
              Offset(
                  translateX(joint2.x, size, absoluteImageSize, rotation, cameraLensDirection),
                  translateY(joint2.y, size, absoluteImageSize, rotation, cameraLensDirection)),
              paint);
        }
      }

      // Draw Arms
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
      paintLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
      paintLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);

      // Draw Body
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);

      // Draw Legs (This was where the previous code cut off)
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
      paintLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
      paintLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
      paintLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
    }
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.poses != poses;
  }
}

/// TRANSLATION HELPERS
/// These map the coordinates from the camera image (e.g. 1920x1080) to the screen (e.g. 400x800)
double translateX(double x, Size canvasSize, Size imageSize, InputImageRotation rotation, CameraLensDirection cameraLensDirection) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      // When rotated 90/270, x corresponds to height
      return x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      // Standard orientation
      return x * canvasSize.width / imageSize.width;
  }
}

double translateY(double y, Size canvasSize, Size imageSize, InputImageRotation rotation, CameraLensDirection cameraLensDirection) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      // When rotated 90/270, y corresponds to width
      return y * canvasSize.height / (Platform.isIOS ? imageSize.height : imageSize.width);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      // Standard orientation
      return y * canvasSize.height / imageSize.height;
  }
}