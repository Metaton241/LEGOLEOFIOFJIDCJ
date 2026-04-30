import 'package:dio/dio.dart';

/// No-op since v1.5.0. Each Dio client used to have its transport overridden
/// here (HTTP CONNECT proxy in v1.3.x, in-process VLESS tunnel in v1.4.x);
/// now we route via a Cloudflare Worker by simply pointing each client's
/// `baseUrl` at `https://<worker>.workers.dev/...`. No HttpClient adapter
/// changes are required.
///
/// Kept as a hook so the three clients still call `applyEnvProxy(_dio)` —
/// a future transport (system VPN, mTLS, etc.) can be slotted in here
/// without touching every client again.
void applyEnvProxy(Dio dio) {
  // intentionally empty
}
