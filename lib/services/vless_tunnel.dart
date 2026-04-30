import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

/// Singleton that runs an embedded Xray-core inside the app process and
/// exposes a local HTTP proxy on `127.0.0.1:_localPort`. Upstream protocol:
/// VLESS+Reality. To DPI/RKN, traffic looks like a regular TLS handshake to
/// the configured `serverName` (e.g. www.cloudflare.com).
///
/// Mode: `proxyOnly: true` — Xray runs in-process only, no system VPN. This
/// avoids the iOS NEPacketTunnelProvider entitlement.
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

    // Build the full Xray config ourselves — skip flutter_v2ray's V2RayURL
    // parser entirely. The parser's default user object contains odd fields
    // (security=auto, level=8) that interact badly with the bundled Xray
    // version on some setups, causing the core to fail startup → no listener
    // binds → Connection Refused on every port we try.
    final config = _buildConfig(vlessUrl, _localPort);
    if (kDebugMode) {
      final preview = config.length > 800
          ? '${config.substring(0, 800)}…'
          : config;
      debugPrint('[VlessTunnel] config preview: $preview');
    }

    await _v2ray!.startV2Ray(
      remark: 'twink-vless',
      config: config,
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
  /// CONNECT — payload is end-to-end encrypted, the proxy operator cannot
  /// decrypt it.
  IOHttpClientAdapter buildAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:$_localPort';
        return client;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Minimal Xray config: HTTP inbound at 127.0.0.1:10808 + single VLESS+Reality
  // outbound. No routing/dns/extra outbounds — those are common sources of
  // startup failure on different libv2ray builds. The "user object" only has
  // `id` + `encryption` (no `level`, `security`, `alterId`) which matches
  // the Xray-core spec for VLESS users.
  // ---------------------------------------------------------------------------
  static String _buildConfig(String vlessUrl, int httpPort) {
    final p = _parseVless(vlessUrl);

    final user = <String, dynamic>{
      'id': p.uuid,
      'encryption': p.encryption,
    };
    if (p.flow.isNotEmpty) user['flow'] = p.flow;

    final stream = <String, dynamic>{
      'network': p.network,
      'security': p.security,
    };
    if (p.security == 'reality') {
      stream['realitySettings'] = {
        'show': false,
        'fingerprint': p.fingerprint,
        'serverName': p.sni,
        'publicKey': p.publicKey,
        'shortId': p.shortId,
        'spiderX': '',
      };
    } else if (p.security == 'tls') {
      stream['tlsSettings'] = {
        'serverName': p.sni,
        'fingerprint': p.fingerprint,
        'allowInsecure': false,
      };
    }

    final config = {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'http-in',
          'port': httpPort,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'settings': {'timeout': 0},
        },
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': p.host,
                'port': p.port,
                'users': [user],
              },
            ],
          },
          'streamSettings': stream,
        },
      ],
    };
    return jsonEncode(config);
  }

  static _ParsedVless _parseVless(String url) {
    // vless://uuid@host:port?param1=v&param2=v#remark
    final u = Uri.parse(url);
    if (u.scheme != 'vless') {
      throw FormatException('Not a vless:// URL: $url');
    }
    final uuid = u.userInfo;
    final host = u.host;
    final port = u.port == 0 ? 443 : u.port;
    final qp = u.queryParameters;
    return _ParsedVless(
      uuid: uuid,
      host: host,
      port: port,
      encryption: qp['encryption'] ?? 'none',
      flow: qp['flow'] ?? '',
      network: qp['type'] ?? 'tcp',
      security: qp['security'] ?? 'none',
      sni: qp['sni'] ?? host,
      fingerprint: qp['fp'] ?? 'chrome',
      publicKey: qp['pbk'] ?? '',
      shortId: qp['sid'] ?? '',
    );
  }
}

class _ParsedVless {
  final String uuid;
  final String host;
  final int port;
  final String encryption;
  final String flow;
  final String network;
  final String security;
  final String sni;
  final String fingerprint;
  final String publicKey;
  final String shortId;

  const _ParsedVless({
    required this.uuid,
    required this.host,
    required this.port,
    required this.encryption,
    required this.flow,
    required this.network,
    required this.security,
    required this.sni,
    required this.fingerprint,
    required this.publicKey,
    required this.shortId,
  });
}

/// Convenience: apply the running VLESS tunnel to a Dio. No-op if tunnel is
/// not running (clients fall back to direct mode in that case).
void applyTunnel(Dio dio) {
  if (!VlessTunnel.instance.running) return;
  dio.httpClientAdapter = VlessTunnel.instance.buildAdapter();
}
