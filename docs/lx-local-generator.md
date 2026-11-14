# Local generator (iOS) — v1.4.48r2 migration

## Scope

The iOS Settings → Local Generator panel provides an **isolated** in-app
version of the user-provided Yandex Cloud Function generator v1.4.48r2.
The original Yandex service, saved profile subscriptions, and active VPN
connection are left intact.

Inputs: a VLESS subscription source (direct HTTPS URL, SUB_URL variable or
pasted text); all v1.4.48r2 KEY=VALUE environment variables; output variant
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

The raw proxy endpoint does NOT yet exist in the user's v1.4.48r2 Yandex
Function. On direct download failure, the app can use the proxy if configured
and if the function is later updated. The app sends a long secret via
X-Subscription-Proxy-Key and does not pass the original source URL or token.
The server itself must have its own configured subscription source.

## Verification

Node parity test from the uploaded archive:
node test_local_parity.mjs → PARITY_OK 20 (all 20 combinations of profile,
core and platform for deterministic offline fixtures).

This verifies generator logic in Node, not operation on iOS. Xcode CI and
on-device tests must still validate the embedded WebKit runtime,
signing/runtime permissions, local creation and startup.

## Security

No remotely fetched executable JavaScript, no hardcoded subscription secrets,
input data not logged, no silent changes to selected profile. The generator
retains its original minimum 3-node requirement and rejects invalid outputs.
