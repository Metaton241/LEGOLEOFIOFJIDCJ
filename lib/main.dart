import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env is optional — missing file only means API key must be provided later.
  }

  // Fire-and-forget pre-warm of the Cloudflare Worker. The first real request
  // pays a cold-start hit (TLS handshake, Worker spawn, route resolution).
  // Pinging /health here at app launch primes the connection so the user's
  // first analyze tap is immediately fast.
  final baseUrl = (dotenv.env['KIE_BASE_URL'] ?? '').trim();
  if (baseUrl.contains('workers.dev')) {
    final origin = Uri.tryParse(baseUrl);
    if (origin != null) {
      final healthUrl = '${origin.scheme}://${origin.host}/health';
      // Don't await — fire and continue.
      Dio()
          .get<dynamic>(
            healthUrl,
            options: Options(
              receiveTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 5),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                        'Mobile/15E148 Safari/604.1',
              },
            ),
          )
          .catchError((_) => Response(
                requestOptions: RequestOptions(path: healthUrl),
                statusCode: 0,
              ));
    }
  }

  runApp(const ProviderScope(child: TwinkLegoFinderApp()));
}
