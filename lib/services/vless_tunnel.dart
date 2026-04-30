import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

/// Singleton wrapper around `flutter_v2ray` that runs an Xray-core inside the
/// app process and exposes a local HTTP proxy at `127.0.0.1:_localPort`.
///
/// Mode is `proxyOnly: true` — Xray spawns a local listener inside our app
/// only, no system VPN is created. This keeps us free from
/// NEPacketTunnelProvider entitlement on iOS, which would require Apple
/// approval. Only this app's HTTPS traffic is tunneled.
///
/// Upstream protocol: VLESS+Reality, configured via the URL passed to
/// [start]. Xray-core handles the Reality TLS dance — to RKN/DPI the
/// connection looks like a regular TLS handshake to `www.cloudflare.com`.
class VlessTunnel {
  VlessTunnel._();
  static final VlessTunnel instance = VlessTunnel._();

  static const int _localPort = 10808;

  FlutterV2ray? _v2ray;
  bool _initialized = false;
  bool _running = false;
  String _status = 'IDLE';

  bool get running => _running;
  int get port => _localPort;
  String get status => _status;
  String get proxyOrigin => 'http://127.0.0.1:$_localPort';

  /// Boots Xray-core if not already running and starts the VLESS tunnel.
  /// Idempotent — calling twice is a no-op when already running.
  Future<void> start({required String vlessUrl}) async {
    if (_running) return;

    if (!_initialized) {
      _v2ray = FlutterV2ray(onStatusChanged: (s) {
        _status = s.state.toString();
        if (kDebugMode) debugPrint('[VlessTunnel] status: ${s.state}');
      });
      await _v2ray!.initializeV2Ray();
      _initialized = true;
    }

    final V2RayURL parser = FlutterV2ray.parseFromURL(vlessUrl);
    final cfg = parser.getFullConfiguration();

    await _v2ray!.startV2Ray(
      remark: parser.remark.isNotEmpty ? parser.remark : 'twink-vless',
      config: cfg,
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: true,
    );
    _running = true;
  }

  Future<void> stop() async {
    if (!_running || _v2ray == null) return;
    await _v2ray!.stopV2Ray();
    _running = false;
  }

  /// Returns a Dio adapter that routes ALL HTTPS traffic through the local
  /// Xray HTTP-proxy. The TLS handshake to upstream still happens after
  /// CONNECT — payload is end-to-end encrypted, the proxy operator (us)
  /// cannot decrypt it.
  IOHttpClientAdapter buildAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:$_localPort';
        return client;
      },
    );
  }
}

/// Convenience: apply the running VLESS tunnel to a Dio. No-op if tunnel is
/// not running (clients fall back to direct mode in that case).
void applyTunnel(Dio dio) {
  if (!VlessTunnel.instance.running) return;
  dio.httpClientAdapter = VlessTunnel.instance.buildAdapter();
}
