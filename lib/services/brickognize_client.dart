import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'proxy_config.dart';

/// One candidate match for an uploaded image from the Brickognize API.
class BrickognizeItem {
  final String id; // LEGO design id, e.g. "3001"
  final String name;
  final String? category;
  final String type; // "part"|"set"|"fig"|"sticker"
  final double score; // 0..1

  const BrickognizeItem({
    required this.id,
    required this.name,
    required this.type,
    required this.score,
    this.category,
  });

  factory BrickognizeItem.fromJson(Map<String, dynamic> j) => BrickognizeItem(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        category: j['category']?.toString(),
        type: (j['type'] ?? 'part').toString(),
        score: (j['score'] is num) ? (j['score'] as num).toDouble() : 0.0,
      );
}

class BrickognizeException implements Exception {
  final String message;
  BrickognizeException(this.message);
  @override
  String toString() => 'BrickognizeException: $message';
}

/// Thin wrapper over the Brickognize /predict/parts/ endpoint.
///
/// Brickognize is a free public service — avoid hammering it. All consumers
/// should go through [IdentificationPipeline] which applies rate limiting.
class BrickognizeClient {
  final Dio _dio;

  BrickognizeClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.brickognize.com',
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
              headers: {
                'User-Agent': 'TwinkLegoFinder/1.0 (flutter)',
              },
            )) {
    if (dio == null) applyEnvProxy(_dio);
  }

  /// Submit a cropped brick image and get the ranked list of candidate parts.
  /// Returns the top items (usually 1-5). Empty list on failure.
  Future<List<BrickognizeItem>> identifyPart(
    Uint8List jpegBytes, {
    String filename = 'crop.jpg',
  }) async {
    final form = FormData.fromMap({
      'query_image': MultipartFile.fromBytes(
        jpegBytes,
        filename: filename,
        contentType: DioMediaType('image', 'jpeg'),
      ),
    });

    Response resp;
    try {
      resp = await _dio.post('/predict/parts/', data: form);
    } on DioException catch (e) {
      throw BrickognizeException('Network: ${e.message}');
    }

    final data = resp.data;
    if (data is! Map) {
      throw BrickognizeException('Unexpected response shape');
    }
    final items = (data['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((m) => BrickognizeItem.fromJson(m.cast<String, dynamic>()))
        .where((it) => it.id.isNotEmpty)
        .toList();
  }
}
