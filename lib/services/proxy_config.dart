import 'package:dio/dio.dart';

import 'vless_tunnel.dart';

/// Apply the embedded VLESS+Reality tunnel to a Dio instance, if running.
/// No-op when the tunnel hasn't booted yet — the client will hit the upstream
/// directly and surface a connection error from there.
///
/// This wrapper is the single integration point used by KieClient,
/// BrickognizeClient and RebrickableClient. It used to read PROXY_* env vars
/// for an HTTP CONNECT proxy; that mode was removed in v1.4.0 in favour of
/// the in-process VLESS tunnel.
void applyEnvProxy(Dio dio) {
  applyTunnel(dio);
}
