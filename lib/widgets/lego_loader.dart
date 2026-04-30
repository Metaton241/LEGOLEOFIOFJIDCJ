import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'lego_brick.dart';

/// Full-screen loading overlay with an animated LEGO brick, elapsed timer,
/// and a rotating status message. Optionally shows a thumbnail of the image
/// being analyzed with a scanning line over it.
class LegoLoader extends StatefulWidget {
  final File? thumbnail;
  final List<String> messages;
  final int progressDone;
  final int progressTotal;
  final String? progressLabel;

  LegoLoader({
    super.key,
    this.thumbnail,
    List<String>? messages,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.progressLabel,
  }) : messages = messages ??
            const [
              'Uploading photo…',
              'Scanning the pile…',
              'Identifying shapes…',
              'Matching against inventory…',
              'Almost there…',
            ];

  @override
  State<LegoLoader> createState() => _LegoLoaderState();
}

class _LegoLoaderState extends State<LegoLoader> {
  Timer? _msgTick;
  int _msgIdx = 0;

  @override
  void initState() {
    super.initState();
    _msgTick = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      setState(() =>
          _msgIdx = (_msgIdx + 1).clamp(0, widget.messages.length - 1));
    });
  }

  @override
  void dispose() {
    _msgTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.2,
          colors: [Color(0xFF1C1C1C), Color(0xFF0A0A0A)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              const AnimatedLegoBrick(size: 160),
              const SizedBox(height: 36),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.2),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: Text(
                  widget.progressLabel?.isNotEmpty == true
                      ? widget.progressLabel!
                      : widget.messages[_msgIdx],
                  key: ValueKey(widget.progressLabel ?? '_m$_msgIdx'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              if (widget.progressTotal > 0) ...[
                const SizedBox(height: 14),
                _ProgressBar(
                  done: widget.progressDone,
                  total: widget.progressTotal,
                ),
              ],
              const Spacer(),
              if (widget.thumbnail != null)
                _ScanningThumbnail(file: widget.thumbnail!),
              const SizedBox(height: 12),
              const Text(
                'Обычно занимает 30–90 секунд',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final int done;
  final int total;
  const _ProgressBar({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.amber),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$done / $total',
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ScanningThumbnail extends StatefulWidget {
  final File file;
  const _ScanningThumbnail({required this.file});

  @override
  State<_ScanningThumbnail> createState() => _ScanningThumbnailState();
}

class _ScanningThumbnailState extends State<_ScanningThumbnail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 160,
        height: 110,
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.file(widget.file, fit: BoxFit.cover),
            ),
            Positioned.fill(
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                return Positioned(
                  left: 0,
                  right: 0,
                  top: 110 * _ctrl.value - 2,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.transparent,
                        AppColors.amber.withValues(alpha: 0.9),
                        Colors.transparent,
                      ]),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.amber.withValues(alpha: 0.6),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 8,
              top: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'SCANNING',
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
