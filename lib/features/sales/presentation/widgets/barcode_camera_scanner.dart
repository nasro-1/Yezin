import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeCameraScanner extends StatefulWidget {
  const BarcodeCameraScanner({super.key});

  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const BarcodeCameraScanner(),
    );
  }

  @override
  State<BarcodeCameraScanner> createState() => _BarcodeCameraScannerState();
}

class _BarcodeCameraScannerState extends State<BarcodeCameraScanner> {
  late final MobileScannerController _controller = MobileScannerController(
    cameraResolution: const Size(640, 480),
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 100,
    facing: CameraFacing.back,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
    ],
    returnImage: false,
    torchEnabled: false,
    autoZoom: false,
  );
  bool _hasResult = false;

  void _handleCapture(BarcodeCapture capture) {
    debugPrint('[BARCODE] detect callback entered');
    if (!mounted) {
      debugPrint('[BARCODE] callback ignored: scanner not mounted');
      return;
    }
    if (_hasResult) {
      debugPrint(
          '[BARCODE] callback ignored: first valid result already handled');
      return;
    }
    if (capture.barcodes.isEmpty) {
      debugPrint('[BARCODE] callback ignored: captureResult.barcodes empty');
      return;
    }

    final value = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim())
        .whereType<String>()
        .firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => '',
        );
    debugPrint('[BARCODE] raw value=$value');
    if (value.isEmpty) {
      debugPrint('[BARCODE] callback ignored: raw value empty');
      return;
    }

    _hasResult = true;
    unawaited(_controller.stop());
    Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Scan barcode'),
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: 360,
        height: 440,
        child: MobileScanner(
          controller: _controller,
          onDetect: _handleCapture,
          errorBuilder: (context, error) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Camera permission was denied or the camera is unavailable.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
