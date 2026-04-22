import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../state/analysis_provider.dart';
import '../theme.dart';
import '../widgets/scanner_corners.dart';
import 'tap_identify_screen.dart';

class CapturePileScreen extends ConsumerStatefulWidget {
  const CapturePileScreen({super.key});

  @override
  ConsumerState<CapturePileScreen> createState() => _CapturePileScreenState();
}

class _CapturePileScreenState extends ConsumerState<CapturePileScreen> {
  File? _picked;
  final _picker = ImagePicker();

  Future<void> _pick(ImageSource src) async {
    final x = await _picker.pickImage(source: src, imageQuality: 92);
    if (x == null) return;
    setState(() => _picked = File(x.path));
  }

  void _start() {
    final f = _picked;
    if (f == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TapIdentifyScreen(pileImage: f),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(analysisProvider).busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Шаг 3 — Куча деталей')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Hint(
              icon: Icons.tips_and_updates_outlined,
              text:
                  'Сфотографируй кучу сверху. На следующем экране тапай по каждой детали — Brickognize её определит.',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ScannerCorners(
                active: _picked != null && !busy,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElev,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  clipBehavior: Clip.antiAlias,
                  child: _picked == null
                      ? const _EmptyPreview(
                          icon: Icons.grid_view_rounded,
                          label: 'Фото не выбрано',
                        )
                      : Image.file(_picked!, fit: BoxFit.contain),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Камера'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Галерея'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: (_picked == null || busy) ? null : _start,
                icon: const Icon(Icons.touch_app_rounded),
                label: const Text('Перейти к опознанию'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceElev,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.amber, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  final IconData icon;
  final String label;
  const _EmptyPreview({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: Colors.white24),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 13)),
      ],
    );
  }
}
