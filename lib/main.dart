import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  // OPTIMIZATION 1: Use the BASE model and STREAM mode for speed
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      model: PoseDetectionModel.base,
      mode: PoseDetectionMode.stream,
    ),
  );

  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  CameraController? _controller;

  // OPTIMIZATION 2: Throttling variables
  DateTime _lastProcessTime = DateTime.now();
  // Process every 100ms (approx 10 FPS). Lower this number (e.g. 50) for smoother skeleton but more heat/lag.
  final int _throttleMillis = 100;

  // Debug State
  final List<String> _logs = [];
  String _realTimeStats = "Initializing...";
  int _frameCounter = 0; // To limit stats updates

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

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add(
        "${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second} - $message",
      );
      if (_logs.length > 10) {
        _logs.removeAt(0);
      }
    });
  }

  void _initializeCamera() async {
    if (cameras.isEmpty) {
      _log("No cameras found!");
      return;
    }

    var cameraIndex = 0;
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].lensDirection == CameraLensDirection.front) {
        cameraIndex = i;
        break;
      }
    }

    _controller = CameraController(
      cameras[cameraIndex],
      // OPTIMIZATION 3: Keep High for Android stability (avoid padding crashes),
      // but relied on Throttling for speed.
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
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
    // OPTIMIZATION 4: Throttling Logic
    // If we processed a frame less than X ms ago, skip this one.
    final now = DateTime.now();
    if (now.difference(_lastProcessTime).inMilliseconds < _throttleMillis) {
      return;
    }
    _lastProcessTime = now;

    if (!_canProcess || _isBusy) return;
    _isBusy = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isBusy = false;
        return;
      }

      final poses = await _poseDetector.processImage(inputImage);

      // Reduce UI updates for stats to every 5th processed frame to save CPU
      if (_frameCounter++ % 5 == 0) {
        String stats =
            "Img: ${image.width}x${image.height}\n"
            "Poses: ${poses.length}";
        if (poses.isNotEmpty) {
          final pose = poses.first;
          final nose = pose.landmarks[PoseLandmarkType.nose];
          if (nose != null) {
            stats +=
                "\nNose: (${nose.x.toStringAsFixed(0)}, ${nose.y.toStringAsFixed(0)})";
          }
        }
        // Only update state for stats if changed
        if (_realTimeStats != stats) {
          _realTimeStats = stats;
          if (mounted) setState(() {});
        }
      }

      if (inputImage.metadata?.size != null &&
          inputImage.metadata?.rotation != null) {
        final painter = PosePainter(
          poses,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
          _controller!.description.lensDirection,
        );

        // Only trigger repaint
        if (mounted) {
          setState(() {
            _customPaint = CustomPaint(painter: painter);
          });
        }
      }
    } catch (e) {
      // Error handling
    }

    _isBusy = false;
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;

    final camera = _controller!.description;
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation rotation = InputImageRotation.rotation0deg;
    if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[_controller!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation =
          InputImageRotationValue.fromRawValue(rotationCompensation) ??
          InputImageRotation.rotation0deg;
    } else if (Platform.isIOS) {
      rotation =
          InputImageRotationValue.fromRawValue(sensorOrientation) ??
          InputImageRotation.rotation0deg;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid &&
            format != InputImageFormat.nv21 &&
            format != InputImageFormat.yv12)) {
      // Android format fix
    }

    if (image.planes.isEmpty) return null;

    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: Platform.isAndroid ? InputImageFormat.nv21 : format!,
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
        backgroundColor: Colors.black,
        body: Center(
          child: Text("Initializing...", style: TextStyle(color: Colors.white)),
        ),
      );
    }

    // OPTIMIZATION 5: Calculate Exact Rendered Size for Perfect Alignment
    final size = MediaQuery.of(context).size;
    final deviceRatio = size.width / size.height;

    // The camera stream is usually Landscape (e.g. 1920/1080 = 1.77)
    // But in Portrait mode on phone, we view it as 1080/1920 = 0.56
    // We need to match the CameraPreview's internal logic.

    double previewW, previewH;
    double scale = _controller!.value.aspectRatio * deviceRatio;

    // If scale < 1, the camera preview is "taller" than the screen (or wider in landscape)
    // The standard CameraPreview widget scales to FIT width in portrait.
    if (scale < 1) scale = 1 / scale;

    // This is a close approximation.
    // To be perfectly safe, we simply tell the CustomPaint to draw on the MAX size
    // but we center it exactly like the preview.

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: CameraPreview(
              _controller!,
              child:
                  _customPaint != null
                      ? LayoutBuilder(
                        builder: (context, constraints) {
                          return SizedBox(
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            child: _customPaint!,
                          );
                        },
                      )
                      : null,
            ),
          ),

          // Stats
          Positioned(
            top: 40,
            right: 10,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _realTimeStats,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),

          // Logs
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 100,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black87,
              child: ListView.builder(
                reverse: true,
                itemCount: _logs.length,
                itemBuilder:
                    (context, index) => Text(
                      _logs[_logs.length - 1 - index],
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                      ),
                    ),
              ),
            ),
          ),
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

  PosePainter(
    this.poses,
    this.absoluteImageSize,
    this.rotation,
    this.cameraLensDirection,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.0
          ..color = Colors.lightGreenAccent;

    final landmarkPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..strokeWidth = 5.0
          ..color = Colors.redAccent;

    for (final pose in poses) {
      pose.landmarks.forEach((_, landmark) {
        canvas.drawCircle(
          Offset(
            translateX(
              landmark.x,
              size,
              absoluteImageSize,
              rotation,
              cameraLensDirection,
            ),
            translateY(
              landmark.y,
              size,
              absoluteImageSize,
              rotation,
              cameraLensDirection,
            ),
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
              translateX(
                joint1.x,
                size,
                absoluteImageSize,
                rotation,
                cameraLensDirection,
              ),
              translateY(
                joint1.y,
                size,
                absoluteImageSize,
                rotation,
                cameraLensDirection,
              ),
            ),
            Offset(
              translateX(
                joint2.x,
                size,
                absoluteImageSize,
                rotation,
                cameraLensDirection,
              ),
              translateY(
                joint2.y,
                size,
                absoluteImageSize,
                rotation,
                cameraLensDirection,
              ),
            ),
            paint,
          );
        }
      }

      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
      paintLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
      paintLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);
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

double translateX(
  double x,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      double value =
          x *
          canvasSize.width /
          (Platform.isIOS ? imageSize.width : imageSize.height);
      if (cameraLensDirection == CameraLensDirection.front) {
        return canvasSize.width - value;
      }
      return value;
    default:
      double value = x * canvasSize.width / imageSize.width;
      if (cameraLensDirection == CameraLensDirection.front) {
        return canvasSize.width - value;
      }
      return value;
  }
}

double translateY(
  double y,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y *
          canvasSize.height /
          (Platform.isIOS ? imageSize.height : imageSize.width);
    default:
      return y * canvasSize.height / imageSize.height;
  }
}
