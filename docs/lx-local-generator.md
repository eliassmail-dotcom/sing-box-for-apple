# Local generator (iOS) — v1.4.48r5 migration

## Scope

The iOS Settings → Local Generator panel provides an **isolated** in-app
version of the user-provided Yandex Cloud Function generator v1.4.48r5.
The original Yandex service, saved profile subscriptions, and active VPN
connection are left intact.

Inputs: a VLESS subscription source (direct HTTPS URL, SUB_URL variable or
pasted text); all v1.4.48r5 KEY=VALUE environment variables; output variant
personal/corporate/guest/NB/CD; core lx/upstream, iOS/Windows platform and
log level. An optional authorized raw-node proxy is a separate HTTPS source.

Outputs: JSON preview, JSON file export, and Create Profile (iOS only).
Create Profile validates via LibboxCheckConfig, writes a new local config
file, adds a database Profile and sends profileUpdate. It NEVER changes
selectedProfileID, starts or restarts the VPN, or replaces an existing
subscription/profile.

Generator runs from immutable bundled JavaScript in a non-persistent WebKit
context with network-denying CSP. Native URLSession fetches the subscription.
The source subscription and server tokens are not logged. Equivalent source
nodes + variables + target reproduce the Yandex generator output.

## Coexistence: friends' Yandex profiles

**Keep the original Yandex Function ready-JSON endpoint.** Friends who
cannot sign our unsigned IPA may still import standard sing-box compatible
profiles in other installable clients. The existing API supports upstream
profiles by omitting core=lx.

Two distinct Yandex endpoint roles may coexist:
1. Legacy ready-to-import JSON generator for friends and unmodified clients,
   including its own pools, routing, DNS and selectors.
2. Optional authorized raw-node proxy only for local generator connectivity
   fallback; returns raw subscription nodes, no routing or pools.

The raw proxy endpoint does NOT yet exist in the user's v1.4.48r5 Yandex
Function. On direct download failure, the app can use the proxy if configured
and if the function is later updated. The app sends a long secret via
X-Subscription-Proxy-Key and does not pass the original source URL or token.
The server itself must have its own configured subscription source.

## Verification

Source: uploaded `VPN_Config_v1.4.48r5_VERIFIED_YANDEX_DEPLOY(1).zip`.
The bundled JavaScript contains the 13 exact r5 routing/DNS/profile modules
and their immutable `base-template.json`, adapted to a synchronous,
network-disabled CommonJS registry for WebKit. No live subscription or
Yandex tokens are embedded.

Verification in an independent Node VM:
- Upstream r5 source tests: 18/18 PASS.
- Bundled WebKit-compatible generator vs native r5 source: 20/20 JSON outputs
  byte-identical across core (LX/stock), variant (corporate/personal/guest/NB/CD)
  and platform (iOS/Windows), using synthetic nodes.
- With 2 Gemini exits, Super A has 4 paths, VLESS uses
  `bootstrap-direct-dns-group`, and Cloudflare/Google bootstrap-DoH
  does not include a `detour`. `NET_FALLBACK=true` enables
  `route.auto_detect_interface`.
- Bundled uncompressed JS SHA-256:
  `efde145e9068caf1b7f1aa095b5ac8d025aafb292045b5f196e3366d24490c6a`.

These checks verify static and deterministic generator parity, **not**
signed-device VPN connectivity. The Xcode simulator and on-device tests
must still validate embedded WebKit execution, signing, startup and routing.

## Security

No remotely fetched executable JavaScript, no hardcoded subscription secrets,
input data not logged, no silent changes to selected profile. The generator
retains its original minimum 3-node requirement and rejects invalid outputs.
