import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/detection.dart';
import '../models/lego_part.dart';
import '../state/analysis_provider.dart';
import '../widgets/bbox_overlay.dart';
import '../widgets/cropped_thumb.dart';
import '../widgets/parts_sheet.dart';

class ResultScreen extends ConsumerWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(analysisProvider);
    final pile = st.pileImage;
    final inventory = st.inventory;
    final detections = st.detections;

    if (pile == null) {
      return const Scaffold(body: Center(child: Text('Нет фото кучи')));
    }

    final foundCounts = <String, int>{};
    for (final d in detections) {
      if (d.confidence < 0.5) continue;
      foundCounts[d.partId] = (foundCounts[d.partId] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Результат'),
        actions: [
          IconButton(
            onPressed: () {
              ref.read(analysisProvider.notifier).reset();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: BboxOverlay(
              imageFile: pile,
              detections: detections,
              onTapDetection: (d) => _showDetection(
                context,
                d,
                inventory,
                pile,
                foundCounts[d.partId] ?? 0,
              ),
            ),
          ),
          PartsSheet(inventory: inventory, foundCounts: foundCounts),
        ],
      ),
    );
  }

  void _showDetection(
    BuildContext context,
    Detection d,
    List<LegoPart> inventory,
    File pile,
    int foundCount,
  ) {
    final part = inventory.firstWhere(
      (p) => p.partId == d.partId,
      orElse: () => LegoPart(
        partId: d.partId,
        name: 'Неизвестная деталь',
        color: '—',
        qty: 0,
      ),
    );

    final confColor = d.confidence >= 0.7
        ? Colors.greenAccent
        : d.confidence >= 0.5
            ? Colors.orangeAccent
            : Colors.redAccent;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 96,
                    height: 96,
                    color: Colors.black38,
                    child: CroppedThumb(file: pile, detection: d),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        part.name,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text('Цвет: ${part.color}',
                          style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 2),
                      Text('part_id: #${part.partId}',
                          style: const TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _stat(
                  'Нужно',
                  part.qty > 0 ? '${part.qty}' : '—',
                  Colors.white,
                ),
                const SizedBox(width: 12),
                _stat(
                  'Найдено',
                  '$foundCount',
                  foundCount >= part.qty && part.qty > 0
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 12),
                _stat(
                  'Уверенность',
                  '${(d.confidence * 100).round()}%',
                  confColor,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white60)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ],
          ),
        ),
      );
}


