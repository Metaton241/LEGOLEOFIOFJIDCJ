import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/vless_tunnel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env is optional — missing file only means API key must be provided later.
  }

  // Start the embedded VLESS+Reality tunnel before any HTTP client is built.
  // Failures are non-fatal: the app still launches, but kie.ai requests will
  // surface a connection error so the user knows the tunnel didn't come up.
  final vlessUrl = (dotenv.env['VLESS_URL'] ?? '').trim();
  if (vlessUrl.isNotEmpty) {
    try {
      await VlessTunnel.instance.start(vlessUrl: vlessUrl);
    } catch (e, st) {
      if (kDebugMode) debugPrint('[main] VLESS tunnel failed to start: $e\n$st');
    }
  }

  runApp(const ProviderScope(child: TwinkLegoFinderApp()));
}
