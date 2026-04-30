import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// HTTP/HTTPS CONNECT proxy configuration loaded from `.env`.
///
/// The proxy is used as a TCP transport: all TLS handshakes to upstream
/// servers (api.kie.ai, brickognize, rebrickable) still happen end-to-end
/// **after** the CONNECT, so the proxy operator cannot decrypt payloads or
/// read API keys. The proxy IP is visible on L3/L4, but request bodies are
/// fully shielded by TLS.
///
/// Why this exists: api.kie.ai is unreliable from Russia. Routing through a
/// foreign HTTP proxy keeps the app working without a self-hosted relay.
class ProxyConfig {
  final String host;
  final int port;
  final String? username;
  final String? password;

  const ProxyConfig({
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  /// Reads `PROXY_HOST` / `PROXY_PORT` / `PROXY_USER` / `PROXY_PASS` from env.
  /// Returns null when the proxy is not configured (direct mode).
  static ProxyConfig? fromEnv() {
    final host = (dotenv.env['PROXY_HOST'] ?? '').trim();
    final portStr = (dotenv.env['PROXY_PORT'] ?? '').trim();
    if (host.isEmpty || portStr.isEmpty) return null;
    final port = int.tryParse(portStr);
    if (port == null || port <= 0) return null;
    final user = (dotenv.env['PROXY_USER'] ?? '').trim();
    final pass = (dotenv.env['PROXY_PASS'] ?? '').trim();
    return ProxyConfig(
      host: host,
      port: port,
      username: user.isEmpty ? null : user,
      password: pass.isEmpty ? null : pass,
    );
  }

  /// Builds an `IOHttpClientAdapter` whose underlying `HttpClient` always
  /// routes via this HTTP CONNECT proxy. Authenticated when creds are set.
  IOHttpClientAdapter buildAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY $host:$port';
        if (username != null && password != null) {
          client.addProxyCredentials(
            host,
            port,
            '', // realm — empty matches any
            HttpClientBasicCredentials(username!, password!),
          );
        }
        return client;
      },
    );
  }

  @override
  String toString() => 'ProxyConfig($host:$port${username != null ? " (auth)" : ""})';
}

/// Apply the env-configured proxy to a Dio instance (no-op if not configured).
/// Used by the three HTTP clients (KieClient, BrickognizeClient,
/// RebrickableClient) when they create their default Dio.
void applyEnvProxy(Dio dio) {
  final cfg = ProxyConfig.fromEnv();
  if (cfg == null) return;
  dio.httpClientAdapter = cfg.buildAdapter();
}
