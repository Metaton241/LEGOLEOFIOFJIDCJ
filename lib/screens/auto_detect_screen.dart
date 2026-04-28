import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/analysis_provider.dart';
import '../widgets/lego_loader.dart';
import 'result_screen.dart';

/// Runs `analyzePileAuto` once on entry. Shows the LegoLoader while waiting
/// for the model. On success — pushReplacement to ResultScreen.
/// On error — pop back with a snackbar.
class AutoDetectScreen extends ConsumerStatefulWidget {
  final File pileImage;
  const AutoDetectScreen({super.key, required this.pileImage});

  @override
  ConsumerState<AutoDetectScreen> createState() => _AutoDetectScreenState();
}

class _AutoDetectScreenState extends ConsumerState<AutoDetectScreen> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    await ref.read(analysisProvider.notifier).analyzePileAuto(widget.pileImage);
    if (!mounted) return;
    final st = ref.read(analysisProvider);
    if (st.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(st.error!)));
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => const ResultScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(analysisProvider);
    return Scaffold(
      body: LegoLoader(
        thumbnail: widget.pileImage,
        progressLabel: st.progressLabel.isNotEmpty
            ? st.progressLabel
            : (st.busy ? null : 'Готово'),
      ),
    );
  }
}
