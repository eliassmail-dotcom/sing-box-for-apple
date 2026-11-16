# Config Studio 1.2 — DNS UX and routing labels

## User changes

- Dashboard Clash mode card: **Режим маршрутизации** (was **Маршрутизация Google**). This card also includes DIRECT / GLOBAL and is not Google-only.
- Dashboard strategy card: **Выбор узлов** (was generic **Режим**). No selector tags or runtime behavior changed.
- URLTest `idle_timeout`: **Остановка проверок при бездействии**. It stops the periodic node health-check ticker after inactivity; it does not disconnect the VPN.
- JSON `dns.final` is accurately labeled **DNS при отсутствии подходящего правила**, not a global per-route DNS strategy.
- DNS home leads with conceptual transport family views **Direct DNS** and **Proxy DNS** and leaves unknown/system transports in **Прочие и служебные DNS**. Classification is sourced from DNS-server `detour`, the typed server's direct-dial default, and known outbound types. It is a read-only projection, not a new sing-box configuration object.
- The Direct/Proxy family view shows related servers and rules that reference them directly. Do not assume that a `respond` or `race` step belongs only to one family. The complete DNS program is an ordered flow.
- DNS rules now have an ordered, searchable explanation with precise meanings for `route`, `evaluate`, `respond`, `race`, `speculative`, and `match_response`. Preserve every original position. No flattening/reordering of complex DNS logic.
- Address areas describe condition cardinality (`25 точных доменов`) and clarify which route/DNS destinations are **found in JSON**, not a guarantee of effective routing.
- DoH `path` (`/p0`) is explained as the HTTP request path, not a VPN hop or rule number.
- Route→DNS preview suggests **Direct DNS** for a direct outbound and **Proxy DNS** for an ordinary proxy/selector, including Gemini; a dedicated policy overrides automatic inheritance. This remains an unsaved preview.

## Strict limitations

- No writes to sing-box runtime, Yandex generator, OpenConnect, rule order, DNS transport, bootstrap, or any rule-set.
- Existing DNS configuration has servers and an ordered program; it does NOT inherently have persisted named Direct DNS / Proxy DNS profiles. True editable DNS profiles with their own RACE/evaluate/respond sequence, protected corporate DNS and atomically compiled routing+DNS require subsequent editor work.
- An unknown detour or endpoint cannot be forcibly classified as DIRECT or PROXY. Real-time explanation of exactly which DNS rule won also requires runtime instrumentation.

## Verification

- SFUnitTests/StudioDNSExperienceTests.swift checks classification, unclassified detours, original rule positions, evaluate/respond/race, domain count, route family inheritance and labels.
- SFUnitTests/StudioSemanticModelTests.swift verifies composite groups, priority, route/DNS, 222 ordered DNS rules.
- Build unsigned IPA for GBox signing, inspect on actual iPhone.