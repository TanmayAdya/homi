import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'photo_decode_gate.dart';

class RecoveryPhotoReviewCard extends StatelessWidget {
  const RecoveryPhotoReviewCard({
    super.key,
    required this.bytes,
    required this.busy,
    required this.onShowSaved,
    required this.onKeepSaved,
    required this.onKeepDevice,
  });

  final Uint8List? bytes;
  final bool busy;
  final VoidCallback onShowSaved, onKeepSaved, onKeepDevice;

  @override
  Widget build(BuildContext context) => PhotoDecodeGate(
    bytes: bytes,
    builder: (context, ready, failed) => Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'A photo is saved, but the interrupted upload did not return a receipt. Look at the saved photo before choosing which version to keep.',
            ),
            if (bytes != null)
              Image.memory(
                bytes!,
                height: 240,
                cacheWidth: 1024,
                fit: BoxFit.contain,
                semanticLabel: 'Current saved photo',
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 60,
                  child: Center(child: Text('Preview unavailable')),
                ),
              ),
            if (failed)
              const Text(
                'The saved photo could not be opened for review. Reload it or keep your device photo. Both copies are retained until you choose.',
              ),
            OutlinedButton(
              onPressed: busy ? null : onShowSaved,
              child: const Text('Show saved photo'),
            ),
            FilledButton(
              onPressed: busy || !ready ? null : onKeepSaved,
              child: const Text('Keep the saved photo'),
            ),
            TextButton(
              onPressed: busy ? null : onKeepDevice,
              child: const Text('Keep device photo to upload after review'),
            ),
          ],
        ),
      ),
    ),
  );
}
