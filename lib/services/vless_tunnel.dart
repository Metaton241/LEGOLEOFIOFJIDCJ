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

    // Hybrid approach: let flutter_v2ray's parser generate the outbound
    // (it knows the exact format the bundled Xray-core expects), then we
    // overwrite the inbounds with a deterministic HTTP listener on
    // 127.0.0.1:_localPort. If the parser fails, fall back to a fully
    // hand-built config.
    String config;
    try {
      final parser = FlutterV2ray.parseFromURL(vlessUrl);
      final raw = parser.getFullConfiguration();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      m['inbounds'] = [
        {
          'tag': 'http-in',
          'port': _localPort,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'settings': {'timeout': 0},
        },
      ];
      // Drop routing rules that may interfere with proxy-only mode.
      m.remove('routing');
      config = jsonEncode(m);
      if (kDebugMode) {
        debugPrint('[VlessTunnel] parser config (outbound from package, '
            'inbound overridden to 127.0.0.1:$_localPort)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[VlessTunnel] parser failed ($e); using manual config');
      }
      config = _buildConfig(vlessUrl, _localPort);
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
  // Xray config construction (manual). Bypasses flutter_v2ray's parser whose
  // default port is randomized — that broke our PROXY directive on the device.
  // ---------------------------------------------------------------------------
  static String _buildConfig(String vlessUrl, int httpPort) {
    final p = _parseVless(vlessUrl);
    final config = {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'http-in',
          'port': httpPort,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'settings': {
            'timeout': 0,
          },
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls'],
          },
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
                'users': [
                  {
                    'id': p.uuid,
                    'encryption': p.encryption,
                    'flow': p.flow,
                  },
                ],
              },
            ],
          },
          'streamSettings': {
            'network': p.network,
            'security': p.security,
            if (p.security == 'reality')
              'realitySettings': {
                'show': false,
                'fingerprint': p.fingerprint,
                'serverName': p.sni,
                'publicKey': p.publicKey,
                'shortId': p.shortId,
                'spiderX': '',
              }
            else if (p.security == 'tls')
              'tlsSettings': {
                'serverName': p.sni,
                'fingerprint': p.fingerprint,
              },
          },
        },
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {
            'type': 'field',
            'ip': ['geoip:private'],
            'outboundTag': 'direct',
          },
        ],
      },
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
