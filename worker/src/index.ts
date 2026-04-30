/// <reference types="@cloudflare/workers-types" />

/**
 * TwinkLegoFinder relay — proxies authenticated kie.ai requests.
 *
 * Why this exists:
 *  - api.kie.ai is sometimes blocked / unstable from Russia.
 *  - Hardcoding the API key in the APK is a leak risk.
 *
 * The Worker holds KIE_API_KEY as a secret and adds the Authorization
 * header to every upstream request. Clients call us with NO auth header.
 * Only the /kie/* prefix is proxied — everything else returns 404 so the
 * Worker cannot be abused as an open proxy.
 */

const UPSTREAM = 'https://api.kie.ai';
const ALLOWED_PREFIX = '/kie/';

export interface Env {
  KIE_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Health check — easy way to verify the Worker is alive.
    if (url.pathname === '/' || url.pathname === '/health') {
      return new Response(JSON.stringify({ ok: true, service: 'twink-relay' }), {
        headers: { 'content-type': 'application/json' },
      });
    }

    if (!url.pathname.startsWith(ALLOWED_PREFIX)) {
      return new Response('not found', { status: 404 });
    }

    if (!env.KIE_API_KEY) {
      return new Response(
        JSON.stringify({ error: 'KIE_API_KEY secret is not set on the Worker' }),
        { status: 500, headers: { 'content-type': 'application/json' } },
      );
    }

    // /kie/foo/bar  ->  /foo/bar
    const upstreamPath = url.pathname.slice(ALLOWED_PREFIX.length - 1);
    const upstreamUrl = UPSTREAM + upstreamPath + url.search;

    const headers = new Headers(request.headers);
    headers.set('Authorization', `Bearer ${env.KIE_API_KEY}`);
    // Strip Cloudflare- and proxy-injected headers so kie.ai sees a clean request.
    headers.delete('host');
    headers.delete('cf-connecting-ip');
    headers.delete('cf-ray');
    headers.delete('cf-visitor');
    headers.delete('cf-ipcountry');
    headers.delete('x-forwarded-for');
    headers.delete('x-forwarded-proto');
    headers.delete('x-real-ip');

    const init: RequestInit = {
      method: request.method,
      headers,
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
    };

    try {
      return await fetch(upstreamUrl, init);
    } catch (e) {
      return new Response(
        JSON.stringify({ error: 'upstream fetch failed', detail: String(e) }),
        { status: 502, headers: { 'content-type': 'application/json' } },
      );
    }
  },
};
