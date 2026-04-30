import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/detection.dart';
import '../models/lego_part.dart';
import 'image_service.dart';
import 'prompts.dart';
import 'proxy_config.dart';

class KieException implements Exception {
  final String message;
  final String? rawResponse;
  KieException(this.message, {this.rawResponse});
  @override
  String toString() => 'KieException: $message';
}

class KieClient {
  final Dio _dio;
  final String _apiKey;
  final String _model;

  /// Locked to gemini-2.5-flash (per user request, v1.6.4). The previous
  /// fallback chain caused unpredictable behavior — slow Pro/Claude calls
  /// would timeout, the user couldn't tell which model failed and how to
  /// retry. Now if Flash is unavailable we just retry it 3 times then
  /// surface a clean error.
  static const List<String> _fallbackChain = ['gemini-2.5-flash'];

  static const int _retriesPerModel = 3;

  bool _isClaude(String m) => m.startsWith('claude-');

  // Claude has tighter context limits AND processes images much slower than
  // Gemini. Shrink to 640px / quality 70 so Claude turnaround drops below
  // the 4-min receiveTimeout even on dense inventory pages.
  int _maxSideFor(String m) => _isClaude(m) ? 640 : 1280;
  int _qualityFor(String m) => _isClaude(m) ? 70 : 80;

  /// Short string included in error messages so users can tell whether the
  /// request went through the Cloudflare Worker relay or hit kie.ai directly.
  String get _proxyTag {
    final host = Uri.tryParse(_dio.options.baseUrl)?.host ?? '';
    if (host.endsWith('workers.dev') || host.contains('.workers.dev/')) {
      return 'via $host';
    }
    if (host.isEmpty || host.endsWith('api.kie.ai')) return 'direct';
    return 'via $host';
  }

  KieClient({
    required String apiKey,
    String baseUrl = 'https://api.kie.ai',
    String model = 'gemini-2.5-flash',
    Dio? dio,
  })  : _apiKey = apiKey,
        _model = model,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 30),
              // 90 seconds: covers Gemini Pro vision response time
              // (~30-60s for dense inventory). Cloudflare Worker free tier
              // closes idle connections before this anyway, so any longer
              // is just waiting for nothing — fallback will advance faster.
              receiveTimeout: const Duration(seconds: 90),
              responseType: ResponseType.json,
              // Cloudflare's *.workers.dev anti-bot heuristic returns
              // HTTP 403 (error code 1010) for "non-browser" User-Agents
              // including the default Dart `Dart/<version> (dart:io)` UA.
              // Send a plausible iOS Safari UA so requests aren't rejected.
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                        'Mobile/15E148 Safari/604.1',
              },
            )) {
    // Route through HTTP proxy from .env when one is configured. We only do
    // this when the caller didn't pass their own Dio (so tests can opt out).
    if (dio == null) applyEnvProxy(_dio);
  }

  Future<List<LegoPart>> parseInventory(File image) async {
    final b64 = await ImageService.compressAndEncode(
      image,
      maxSide: _maxSideFor(_model),
      quality: _qualityFor(_model),
    );
    final json = await _chat(Prompts.parseInventory, b64);
    final parts = (json['parts'] as List?) ?? const [];
    return parts
        .whereType<Map>()
        .map((m) => LegoPart.fromJson(m.cast<String, dynamic>()))
        .where((p) => p.partId.isNotEmpty)
        .toList();
  }

  Future<List<Detection>> findParts(File image, List<LegoPart> parts) async {
    final b64 = await ImageService.compressAndEncode(
      image,
      maxSide: _maxSideFor(_model),
      quality: _qualityFor(_model),
    );
    return _findPartsWithBase64(b64, parts);
  }

  /// Same as [findParts] but runs N model calls in parallel, each searching for
  /// a slice of the inventory. Each slice prompt is smaller, so the model
  /// answers faster and we duck under the Cloudflare Worker free-tier
  /// per-request wall-clock limit (~30s on a single subrequest).
  ///
  /// The image is encoded ONCE and shared across slices. Results are merged
  /// then run through the same post-processing (NMS + per-part qty cap) using
  /// the FULL inventory so dedup works across slices.
  Future<List<Detection>> findPartsParallel(
    File image,
    List<LegoPart> parts, {
    int splits = 2,
  }) async {
    if (splits < 2 || parts.length < 2) {
      return findParts(image, parts);
    }
    final b64 = await ImageService.compressAndEncode(
      image,
      maxSide: _maxSideFor(_model),
      quality: _qualityFor(_model),
    );

    // Split inventory into roughly-equal chunks.
    final chunks = <List<LegoPart>>[];
    final chunkSize = (parts.length / splits).ceil();
    for (var i = 0; i < parts.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, parts.length);
      chunks.add(parts.sublist(i, end));
    }

    // Run all chunk calls concurrently; each call uses the same image bytes.
    final futures = chunks.map((chunk) => _findRaw(b64, chunk)).toList();
    final results = await Future.wait(futures);

    // Merge raw detections (already filtered per slice) and re-run global
    // post-processing with the FULL inventory so cross-slice NMS works and
    // qty caps reflect the union.
    final merged = <Detection>[];
    for (final list in results) {
      merged.addAll(list);
    }
    return _postProcess(merged, parts);
  }

  /// Internal helper used by both [findParts] and [findPartsParallel].
  /// Runs one model call against [parts] using a pre-encoded [imageB64]
  /// and returns the filtered (but not yet NMS'd) detections.
  Future<List<Detection>> _findRaw(
      String imageB64, List<LegoPart> parts) async {
    final partsJson = jsonEncode(parts.map((p) => p.toJson()).toList());
    final json = await _chat(Prompts.findParts(partsJson), imageB64);
    final dets = (json['detections'] as List?) ?? const [];
    return dets
        .whereType<Map>()
        .map((m) => Detection.fromJson(m.cast<String, dynamic>()))
        .where((d) =>
            d.partId.isNotEmpty &&
            d.bbox.length == 4 &&
            d.w >= 0.015 &&
            d.h >= 0.015 &&
            d.confidence >= 0.65)
        .toList();
  }

  Future<List<Detection>> _findPartsWithBase64(
      String b64, List<LegoPart> parts) async {
    final raw = await _findRaw(b64, parts);
    return _postProcess(raw, parts);
  }

  /// Tighten model output:
  /// 1. If `inventory` is non-empty, drop detections whose part_id is not in it.
  /// 2. Global NMS at IoU > 0.25 (cross-class) — eliminates the most common
  ///    failure where the model emits 2-3 boxes for the same physical brick
  ///    under different part_ids.
  /// 3. Cap per part_id to inventory qty exactly (no slack).
  static List<Detection> _postProcess(
      List<Detection> raw, List<LegoPart> inventory) {
    if (raw.isEmpty) return raw;

    final qtyByPart = <String, int>{};
    for (final p in inventory) {
      qtyByPart[p.partId] = p.qty;
    }
    final filtered = qtyByPart.isEmpty
        ? raw
        : raw.where((d) => qtyByPart.containsKey(d.partId)).toList();

    // Global NMS (cross-class) — sorts by confidence desc, keeps non-overlapping.
    filtered.sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <Detection>[];
    for (final d in filtered) {
      final clashes = kept.any((k) => _iou(d, k) > 0.25);
      if (!clashes) kept.add(d);
    }

    if (qtyByPart.isEmpty) return kept;

    // Cap per part_id to exact inventory qty — sorted-by-confidence first.
    final perPart = <String, int>{};
    final capped = <Detection>[];
    for (final d in kept) {
      final target = qtyByPart[d.partId] ?? 0;
      final already = perPart[d.partId] ?? 0;
      if (already >= target) continue;
      capped.add(d);
      perPart[d.partId] = already + 1;
    }
    return capped;
  }

  static double _iou(Detection a, Detection b) {
    final ax2 = a.x + a.w, ay2 = a.y + a.h;
    final bx2 = b.x + b.w, by2 = b.y + b.h;
    final ix1 = a.x > b.x ? a.x : b.x;
    final iy1 = a.y > b.y ? a.y : b.y;
    final ix2 = ax2 < bx2 ? ax2 : bx2;
    final iy2 = ay2 < by2 ? ay2 : by2;
    final iw = ix2 - ix1;
    final ih = iy2 - iy1;
    if (iw <= 0 || ih <= 0) return 0.0;
    final inter = iw * ih;
    final union = a.w * a.h + b.w * b.h - inter;
    return union <= 0 ? 0.0 : inter / union;
  }

  Future<Map<String, dynamic>> _chat(String prompt, String imageBase64) async {
    // Try the primary model first; if kie.ai returns "currently being
    // maintained", auto-fallback to other models in the chain. Each model
    // is attempted up to [_retriesPerModel] times in a row, since kie.ai
    // sometimes flips healthy/maintenance state within seconds.
    final base = <String>[
      _model,
      ..._fallbackChain.where((m) => m != _model),
    ];
    final candidates = <String>[
      for (final m in base) ...List.filled(_retriesPerModel, m),
    ];
    Response? resp;
    String? lastErr;
    String? activeModel;
    for (final m in candidates) {
      activeModel = m;
      final isClaude = _isClaude(m);
      final path = isClaude ? '/claude/v1/messages' : '/$m/v1/chat/completions';
      final data = isClaude
          ? {
              'model': m,
              'max_tokens': 4096,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'image',
                      'source': {
                        'type': 'base64',
                        'media_type': 'image/jpeg',
                        'data': imageBase64,
                      },
                    },
                    {'type': 'text', 'text': prompt},
                  ],
                },
              ],
            }
          : {
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': prompt},
                    {
                      'type': 'image_url',
                      'image_url': {
                        'url': 'data:image/jpeg;base64,$imageBase64',
                      },
                    },
                  ],
                },
              ],
              'stream': false,
            };

      try {
        // Authorization is sent only when an explicit API key is configured.
        // When using the relay (`KIE_BASE_URL` points at the Cloudflare Worker),
        // the key is held server-side and the client should NOT include it.
        final headers = <String, String>{
          'Content-Type': 'application/json',
        };
        if (_apiKey.isNotEmpty) {
          headers['Authorization'] = 'Bearer $_apiKey';
        }
        resp = await _dio.post(
          path,
          options: Options(headers: headers),
          data: data,
        );
      } on DioException catch (e) {
        // Auto-fallback on transient gateway/timeout errors as well —
        // 5xx (incl. Cloudflare 502/503/504/520-524) and connection timeouts.
        final code = e.response?.statusCode ?? 0;
        final isTransient = code >= 500 ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.connectionError ||
            // Tunnel may close mid-response when upstream model is in
            // maintenance — try next model in the chain.
            e.type == DioExceptionType.unknown;

        // Build a richer message so the user can tell whether it's a TCP
        // failure (proxy unreachable), TLS issue, auth (407), or upstream.
        final parts = <String>[];
        parts.add(e.type.toString().split('.').last); // e.g. connectionError
        if (code > 0) parts.add('HTTP $code');
        final msg = (e.message ?? '').trim();
        if (msg.isNotEmpty) parts.add(msg);
        final inner = e.error?.toString().trim() ?? '';
        if (inner.isNotEmpty && inner != msg) parts.add(inner);
        final proxyTag = _proxyTag;
        if (proxyTag.isNotEmpty) parts.add(proxyTag);
        lastErr = 'kie.ai $m: ${parts.join(' · ')}';

        if (isTransient) {
          resp = null;
          continue;
        }
        throw KieException(lastErr, rawResponse: e.response?.data?.toString());
      }

      // kie.ai may return errors with HTTP 200 + envelope. Trigger fallback
      // for: maintenance, "Model not supported"/"Operation not found"
      // (model unavailable on this account / mistyped), and any 5xx.
      final d = resp.data;
      if (d is Map && d['code'] is num) {
        final code = (d['code'] as num).toInt();
        final msg = (d['msg']?.toString() ?? '').toLowerCase();
        final isUnavailable = code >= 500 && msg.contains('maintained');
        final isUnsupported = (code == 422 || code == 500) &&
            (msg.contains('not supported') ||
                msg.contains('operation not found'));
        if (isUnavailable || isUnsupported) {
          lastErr = 'kie.ai $m: ${d['msg']}';
          resp = null;
          continue; // try next model in chain
        }
      }
      break; // got a usable response
    }
    if (resp == null) {
      throw KieException(
          lastErr ?? 'kie.ai: все модели недоступны (попробуйте позже)');
    }

    dynamic data = resp.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        throw KieException(
          'Non-JSON response: ${data.length > 400 ? '${data.substring(0, 400)}…' : data}',
          rawResponse: data,
        );
      }
    }
    // kie.ai sometimes returns {"code": 4xx/5xx, "msg": "..."} with HTTP 200.
    if (data is Map && data['code'] is num && (data['code'] as num) >= 400) {
      throw KieException(
        'kie.ai: ${data['msg'] ?? 'unknown error'}',
        rawResponse: data.toString(),
      );
    }
    String? content;
    if (data is Map) {
      // Claude /messages: {content: [{type:"text", text:"..."}, ...]}
      if (activeModel != null && _isClaude(activeModel) && data['content'] is List) {
        final buf = StringBuffer();
        for (final b in (data['content'] as List)) {
          if (b is Map && b['type'] == 'text') {
            buf.write(b['text']?.toString() ?? '');
          }
        }
        content = buf.toString();
      } else if (data['choices'] is List &&
          (data['choices'] as List).isNotEmpty) {
        // OpenAI-compat /v1/chat/completions: {choices:[{message:{content:"..."}}]}
        content = (data['choices'][0]['message']?['content'])?.toString();
      }
    }
    if (content == null || content.isEmpty) {
      final preview = data?.toString() ?? '';
      throw KieException(
        'Empty content. Raw: ${preview.length > 400 ? '${preview.substring(0, 400)}…' : preview}',
        rawResponse: preview,
      );
    }
    return _extractJson(content);
  }

  static Map<String, dynamic> _extractJson(String content) {
    final trimmed = content.trim();
    // Try direct parse.
    try {
      final v = jsonDecode(trimmed);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}

    // Try to strip markdown fences ```json ... ```
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final m = fence.firstMatch(trimmed);
    if (m != null) {
      try {
        final v = jsonDecode(m.group(1)!);
        if (v is Map<String, dynamic>) return v;
      } catch (_) {}
    }

    // Try to grab the first {...} block.
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final v = jsonDecode(trimmed.substring(start, end + 1));
        if (v is Map<String, dynamic>) return v;
      } catch (_) {}
    }

    throw KieException('Response is not valid JSON', rawResponse: content);
  }
}
