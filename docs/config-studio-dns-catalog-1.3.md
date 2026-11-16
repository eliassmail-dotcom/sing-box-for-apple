# Config Studio 1.3 — DNS roles, catalog, and priority draft (build 17)

## Goals

The prior design exposed a 210-step chronological DNS program, which is not a useful settings UX.
This version follows Karing's role-oriented DNS presentation and catalog selection while retaining
a user-friendly priority model. It is a **read-only-on-VPN draft**, not a DNS-policy writer.

## Screen architecture

- **Internet traffic:** Direct DNS and Proxy DNS (including Gemini).
- **Service connections:** DNS for proxy host names and DNS bootstrap for names of DNS servers.
- **DNS catalog:** active configuration's full DNS transport URIs first, then a short curated list;
  choose independently with checkboxes, as in Karing.
- **Inside a role:** selected DNS entries, 01–09 priority menu. Same level = planned parallel
  candidate group; next level = planned fallback. Both the list and the displayed grouping are
  working *session-only UI state*.
- **Current configuration:** exact `dns.final` meaning, existing address exceptions and ordered
  DNS rules available under the diagnostic section, not in main navigation.

## Safety and accuracy

- Do not classify a DNS server as "Direct DNS" simply because its *transport* uses DIRECT.
  Transport detour and destination DNS purpose are different axes.
- Existing `dns.rules`, `evaluate`/`respond`/`race`, SRS bootstrap, OpenConnect DNS and
  corporate rules are untouched.
- Priorities and catalog selection are draft UI only. They do **not** save, overwrite the profile,
  or change the NetworkExtension's running configuration.
- `StudioDNSCatalogEntry.uri` builds a human-readable view of existing DNS objects; it is not
  intended as a lossless serialization or editor. Existing TLS, server resolvers, and detours
  remain in the original JSON.
- Runtime DNS-profile compilation requires a parser/IR plus a checked generator that preserves
  ordered rules, dynamic dependencies, custom response validation, and protected corporate
  exceptions. We must not pretend it is done.
- The dynamic catalog is filtered only by exact duplicate URI, not provider name: several entries
  from Cloudflare/Google may coexist with different protocols.

## Verification

`SFUnitTests/StudioDNSDraftModelTests.swift` covers URI rendering, purpose separation, priority
semantics and non-persistence across fresh draft sessions. Existing 1.2 DNS and LX tests retained.
CI produces an unsigned IPA for GBox signing. Additional physical iPhone runtime QA is still needed.
