import 'package:dio/dio.dart';

import '../models/lego_part.dart';
import 'proxy_config.dart';

class RebrickableException implements Exception {
  final String message;
  RebrickableException(this.message);
  @override
  String toString() => 'RebrickableException: $message';
}

/// Pulls official set inventories from Rebrickable.
///
/// Docs: https://rebrickable.com/api/v3/docs/
///
/// The free public API requires a key that each user registers for themselves.
/// We read it from [apiKey]; if empty, [isConfigured] returns false and calls
/// will throw so the UI can show a helpful error.
class RebrickableClient {
  final String apiKey;
  final Dio _dio;

  RebrickableClient({required this.apiKey, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://rebrickable.com',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                        'Mobile/15E148 Safari/604.1',
              },
            )) {
    if (dio == null) applyEnvProxy(_dio);
  }

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Fetches the parts inventory for a given set number (e.g. "75192" or "75192-1").
  /// Pages through all results. Normalizes into [LegoPart].
  Future<List<LegoPart>> fetchSetParts(String setNumber) async {
    if (!isConfigured) {
      throw RebrickableException(
          'REBRICKABLE_API_KEY не задан в .env. Получи ключ на rebrickable.com/api и вставь.');
    }
    final set = _normalizeSetNumber(setNumber);
    final parts = <LegoPart>[];
    String path = '/api/v3/lego/sets/$set/parts/?page_size=1000';

    while (path.isNotEmpty) {
      Response resp;
      try {
        resp = await _dio.get(
          path,
          options: Options(headers: {
            'Authorization': 'key $apiKey',
            'Accept': 'application/json',
          }),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          throw RebrickableException('Набор $set не найден на Rebrickable.');
        }
        if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
          throw RebrickableException('Неверный REBRICKABLE_API_KEY.');
        }
        throw RebrickableException('Сеть: ${e.message}');
      }

      final data = resp.data;
      if (data is! Map) {
        throw RebrickableException('Неожиданный формат ответа Rebrickable');
      }
      final results = (data['results'] as List?) ?? const [];
      for (final r in results) {
        if (r is! Map) continue;
        final isSpare = r['is_spare'] == true;
        if (isSpare) continue; // skip spare-part duplicates
        final partObj = r['part'];
        if (partObj is! Map) continue;
        final colorObj = r['color'];
        final partNum = partObj['part_num']?.toString() ?? '';
        if (partNum.isEmpty) continue;
        final name = partObj['name']?.toString() ?? '';
        final colorName = (colorObj is Map)
            ? (colorObj['name']?.toString() ?? '')
            : '';
        final qty = (r['quantity'] is num) ? (r['quantity'] as num).toInt() : 1;
        parts.add(LegoPart(
          partId: partNum,
          name: name,
          color: colorName.toLowerCase(),
          qty: qty,
        ));
      }

      final next = data['next']?.toString();
      if (next == null || next.isEmpty) break;
      // Rebrickable 'next' is an absolute URL — convert back to relative.
      final uri = Uri.parse(next);
      path = '${uri.path}?${uri.query}';
    }

    // Merge duplicates: same (part_id, color) with different quantities.
    final merged = <String, LegoPart>{};
    for (final p in parts) {
      final key = '${p.partId}|${p.color}';
      if (merged.containsKey(key)) {
        final existing = merged[key]!;
        merged[key] = existing.copyWith(qty: existing.qty + p.qty);
      } else {
        merged[key] = p;
      }
    }
    return merged.values.toList();
  }

  String _normalizeSetNumber(String raw) {
    final n = raw.trim();
    if (n.contains('-')) return n;
    return '$n-1'; // Rebrickable stores sets with a version suffix.
  }

  /// Converts LEGO Element IDs (7-digit catalogue numbers printed in
  /// instruction inventories) to BrickLink-style Design IDs that Brickognize
  /// returns.
  ///
  /// Only ids with 6+ digits are converted — shorter ones are assumed to be
  /// design ids already and are passed through unchanged. Returns a map
  /// element_id → design_id. Missing lookups are silently omitted.
  Future<Map<String, String>> convertElementIds(
    Iterable<String> elementIds, {
    int concurrency = 3,
  }) async {
    if (!isConfigured) return const {};
    final todo = elementIds
        .where((id) => id.length >= 6 && RegExp(r'^\d+$').hasMatch(id))
        .toSet()
        .toList();
    if (todo.isEmpty) return const {};

    final out = <String, String>{};
    int cursor = 0;
    Future<void> worker() async {
      while (true) {
        final int? taskIdx = () {
          if (cursor >= todo.length) return null;
          return cursor++;
        }();
        if (taskIdx == null) break;
        final elementId = todo[taskIdx];
        try {
          final resp = await _dio.get(
            '/api/v3/lego/elements/$elementId/',
            options: Options(headers: {
              'Authorization': 'key $apiKey',
              'Accept': 'application/json',
            }),
          );
          final data = resp.data;
          if (data is Map) {
            final part = data['part'];
            if (part is Map) {
              final designId = part['part_num']?.toString();
              if (designId != null && designId.isNotEmpty) {
                out[elementId] = designId;
              }
            }
          }
        } catch (_) {
          // Missing element — ignore.
        }
      }
    }

    await Future.wait([for (var s = 0; s < concurrency; s++) worker()]);
    return out;
  }
}
