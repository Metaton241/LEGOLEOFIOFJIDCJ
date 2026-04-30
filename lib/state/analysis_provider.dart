import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/analysis_snapshot.dart';
import '../models/detection.dart';
import '../models/lego_part.dart';
import '../services/brickognize_client.dart';
import '../services/element_lookup.dart';
import '../services/history_service.dart';
import '../services/kie_client.dart';
import '../services/rebrickable_client.dart';

final kieClientProvider = Provider<KieClient>((ref) {
  final apiKey = dotenv.env['KIE_API_KEY'] ?? '';
  final baseUrl = dotenv.env['KIE_BASE_URL'] ?? 'https://api.kie.ai';
  final model = dotenv.env['KIE_MODEL'] ?? 'gemini-2.5-flash';
  return KieClient(apiKey: apiKey, baseUrl: baseUrl, model: model);
});

final brickognizeClientProvider =
    Provider<BrickognizeClient>((ref) => BrickognizeClient());

final rebrickableClientProvider = Provider<RebrickableClient>((ref) {
  return RebrickableClient(apiKey: dotenv.env['REBRICKABLE_API_KEY'] ?? '');
});

final historyServiceProvider =
    Provider<HistoryService>((ref) => HistoryService());

class AnalysisState {
  final File? inventoryImage;
  final List<LegoPart> inventory;
  final File? pileImage;
  final List<Detection> detections;
  final bool busy;
  final String? error;
  final String? setLabel;
  final List<AnalysisSnapshot> pastRuns; // matched-by-fingerprint history
  final bool loadedFromHistory;
  final String progressLabel;

  const AnalysisState({
    this.inventoryImage,
    this.inventory = const [],
    this.pileImage,
    this.detections = const [],
    this.busy = false,
    this.error,
    this.setLabel,
    this.pastRuns = const [],
    this.loadedFromHistory = false,
    this.progressLabel = '',
  });

  AnalysisState copyWith({
    File? inventoryImage,
    List<LegoPart>? inventory,
    File? pileImage,
    List<Detection>? detections,
    bool? busy,
    String? error,
    bool clearError = false,
    String? setLabel,
    bool clearSetLabel = false,
    List<AnalysisSnapshot>? pastRuns,
    bool? loadedFromHistory,
    String? progressLabel,
  }) =>
      AnalysisState(
        inventoryImage: inventoryImage ?? this.inventoryImage,
        inventory: inventory ?? this.inventory,
        pileImage: pileImage ?? this.pileImage,
        detections: detections ?? this.detections,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
        setLabel: clearSetLabel ? null : (setLabel ?? this.setLabel),
        pastRuns: pastRuns ?? this.pastRuns,
        loadedFromHistory: loadedFromHistory ?? this.loadedFromHistory,
        progressLabel: progressLabel ?? this.progressLabel,
      );
}

class AnalysisController extends StateNotifier<AnalysisState> {
  final KieClient _client;
  final HistoryService _history;
  final RebrickableClient _rebrickable;
  AnalysisController(this._client, this._history, this._rebrickable)
      : super(const AnalysisState());

  void reset() => state = const AnalysisState();

  void setLabel(String? label) {
    state = state.copyWith(setLabel: label, clearSetLabel: label == null);
  }

  bool get rebrickableConfigured => _rebrickable.isConfigured;

  /// Bypass photo OCR: fetch the official set inventory from Rebrickable.
  Future<void> loadFromSetNumber(String setNumber) async {
    state = state.copyWith(
      busy: true,
      clearError: true,
      setLabel: setNumber,
      progressLabel: 'Загружаю набор #$setNumber с Rebrickable…',
    );
    try {
      final parts = await _rebrickable.fetchSetParts(setNumber);
      final snap = AnalysisSnapshot(
        id: '_tmp',
        createdAt: DateTime.now(),
        inventory: parts,
        detections: const [],
      );
      final past = await _history.findByFingerprint(snap.fingerprint);
      state = state.copyWith(
        inventory: parts,
        busy: false,
        pastRuns: past,
        progressLabel: '',
      );
    } catch (e) {
      state = state.copyWith(busy: false, error: e.toString(), progressLabel: '');
    }
  }

  Future<void> parseInventory(File image) async {
    state = state.copyWith(
      inventoryImage: image,
      busy: true,
      clearError: true,
      progressLabel: 'Распознаю инвентарь…',
    );
    try {
      var parts = await _client.parseInventory(image);

      // Convert LEGO Element IDs (printed in instructions) to BrickLink-style
      // Design IDs so downstream Brickognize matching works.
      final needsResolve = parts
          .where((p) =>
              p.partId.length >= 6 && RegExp(r'^\d+$').hasMatch(p.partId))
          .map((p) => p.partId)
          .toSet();
      if (needsResolve.isNotEmpty) {
        state = state.copyWith(progressLabel: 'Сверяю ID с каталогом…');
        final offline = await ElementLookup().resolveAll(needsResolve);
        final stillMissing = needsResolve.difference(offline.keys.toSet());
        Map<String, String> mapping = Map.of(offline);
        if (stillMissing.isNotEmpty && _rebrickable.isConfigured) {
          try {
            final online = await _rebrickable.convertElementIds(stillMissing);
            mapping.addAll(online);
          } catch (_) {
            // Non-fatal.
          }
        }
        if (mapping.isNotEmpty) {
          parts = parts
              .map((p) => mapping.containsKey(p.partId)
                  ? p.copyWith(partId: mapping[p.partId]!)
                  : p)
              .toList();
        }
      }

      final snap = AnalysisSnapshot(
        id: '_tmp',
        createdAt: DateTime.now(),
        inventory: parts,
        detections: const [],
      );
      final past = await _history.findByFingerprint(snap.fingerprint);
      state = state.copyWith(
        inventory: parts,
        busy: false,
        pastRuns: past,
        progressLabel: '',
      );
    } catch (e) {
      state = state.copyWith(busy: false, error: e.toString());
    }
  }

  void updateInventory(List<LegoPart> parts) {
    state = state.copyWith(inventory: parts);
  }

  /// Auto-detect mode: send the whole pile photo to Gemini/Claude (via
  /// kie.ai) and ask the model to locate every visible part from the
  /// inventory. Each detection is annotated with its inventory name and
  /// `matched` flag, then committed.
  Future<void> analyzePileAuto(File pileImage) async {
    // Choose split based on inventory size:
    //   <4 items  → single call (parallelism overhead exceeds benefit)
    //   4-8 items → 2 streams (split overhead vs win is roughly even)
    //   9+  items → 3 streams (each chunk ~33% of inventory)
    final invSize = state.inventory.length;
    final splits = invSize >= 9 ? 3 : (invSize >= 4 ? 2 : 1);

    state = state.copyWith(
      pileImage: pileImage,
      busy: true,
      clearError: true,
      progressLabel: splits > 1
          ? 'Ищу детали в куче ($splits потока)…'
          : 'Ищу детали в куче…',
    );
    try {
      final raw = splits > 1
          ? await _client.findPartsParallel(pileImage, state.inventory,
              splits: splits)
          : await _client.findParts(pileImage, state.inventory);
      final byId = {for (final p in state.inventory) p.partId: p};
      final inventoryIds = byId.keys.toSet();
      final detections = raw
          .map((d) => Detection(
                partId: d.partId,
                bbox: d.bbox,
                confidence: d.confidence,
                name: d.name ?? byId[d.partId]?.name,
                matched: inventoryIds.isEmpty ||
                    inventoryIds.contains(d.partId),
              ))
          .toList();
      await commitDetections(detections, pileImage: pileImage);
      state = state.copyWith(busy: false, progressLabel: '');
    } catch (e) {
      state = state.copyWith(
        busy: false,
        error: e.toString(),
        progressLabel: '',
      );
    }
  }

  /// Externally-produced detections (from TapIdentifyScreen) — save and
  /// put them into state so ResultScreen can render.
  Future<void> commitDetections(List<Detection> detections,
      {required File pileImage}) async {
    state = state.copyWith(
      pileImage: pileImage,
      detections: detections,
      busy: false,
      clearError: true,
    );
    await _history.save(
      inventory: state.inventory,
      detections: detections,
      setLabel: state.setLabel,
      pileImage: pileImage,
      inventoryImage: state.inventoryImage,
    );
  }

  /// Load a past snapshot into state, bypassing network calls.
  void loadSnapshot(AnalysisSnapshot s) {
    state = AnalysisState(
      inventoryImage:
          s.inventoryImagePath != null ? File(s.inventoryImagePath!) : null,
      pileImage: s.pileImagePath != null ? File(s.pileImagePath!) : null,
      inventory: s.inventory,
      detections: s.detections,
      setLabel: s.setLabel,
      loadedFromHistory: true,
    );
  }
}

final analysisProvider =
    StateNotifierProvider<AnalysisController, AnalysisState>((ref) {
  final client = ref.watch(kieClientProvider);
  final history = ref.watch(historyServiceProvider);
  final rebrickable = ref.watch(rebrickableClientProvider);
  return AnalysisController(client, history, rebrickable);
});
