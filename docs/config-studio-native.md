# Config Studio 1.0 — native-first UI (build 14)

## Product contract

The first release is read-only for active sing-box configuration. It never changes Network Extension, OpenConnect, DNS, rules, legacy A–F selectors or Yandex service.

Three source layers: (1) ProfileManager source, (2) calculated LX effective config, (3) GetRunningConfig from live core when available. Do not conflate these.

## Navigation

ConfigStudioView → StudioCategoryView → StudioNativeDetailView.

- Show nested lists and objects as native navigation and typed rows, not JSON.
- Route/DNS rules: ordered conditions, action and target.
- Groups: members, algorithm, default and URLTest settings.
- Chains: ordered hops; nodes, endpoints, DNS, SRS, HTTP clients and TUN via readable fields.
- Unknown keys are preserved in the model and mapped to generic typed rows.
- Secrets are redacted in both row and JSON presentations.
- Raw JSON is optional under the ellipsis menu only.

## Generator

StudioLocalVariablesView uses tri-state switches, mode menus, numeric inputs, and filter lists for locally owned, nonsecret variables. Empty = inherit generator default. The isolated local generator never updates the active VPN. Its preview reuses StudioGeneratedPreviewView and native category navigation.

Advanced uncatalogued generator variables remain in an opt-in expert panel. The specialized TEST_NODES_JSON field is only a native read-only tree for now; its schema-specific editing is not in 1.0.

## Compatibility and testing

SFUnitTests/ConfigStudioTests.swift tests structural preservation, labels, scalar redaction and nonsecret variable validation. CI validates simulator compilation. Actual VPN runtime state, startup and large configuration performance require signed-device QA.

## Release boundary

Visual inspection and separate local generator settings are supported now. Editing and applying route/DNS/OpenConnect configuration, changing legacy pools, full GUI for all Yandex variables and draft/rollback belong to the future editor release.

## Read-only DNS scheme contract (r6)

Approved terminology:
- **DNS-сервер**: the exact `dns.servers[]` object and its original tag, transport and detour.
- **DNS-схема**: a reusable read-only rendering of actual ordered DNS operations
  (`evaluate`, answer checks via `respond`, final `route`). Identical operation
  sequences can appear in different address groups and are shown as one scheme
  with multiple bindings. They are not currently stored as named objects in sing-box JSON.
- **Группа адресов**: original domain/IP/rule-set conditions and the route/DNS rules
  matched by those conditions. Each group may link to an extracted DNS scheme.
- Do **not** introduce a separate `DNS-логика` entity.

Extraction is deliberately conservative: group only contiguous, tagged
`evaluate` rules with identical query predicates, matching `respond` tag
references and a terminal `route`. Do not group unqualified global
`evaluate` records, silently move or merge rules, or infer a `race` flag
from multiple sequential candidates. Original rule indices, full raw objects,
timeouts, and actual `race`/`speculative` flags remain accessible. Records
not recognized as schemes remain visible in the original ordered rule list.

Direct/Proxy screens now reflect observed DNS server transport/detour
categories, not an empty draft. A Gemini-specific view is populated only by
explicit Gemini DNS conditions, never inferred merely from Gemini routing.
These views are **not** proof of the resolver selected for a particular query:
rule evaluation order, earlier rules and answer-dependent checks still apply.

The r6 baseline uses exact tags `mskix-dns` and `mskix-dns-backup`
and retains DNS fallback, not an invented priority/Race field. The current
offline generator remains r5 until separately upgraded and verified; Config
Studio reads whichever profile JSON is selected, including r6 profiles loaded
from the external generator. No save/apply mutation is part of this change.

## Groups navigation contract (r6, read-only)

The agreed order in **Группы** is:
1. **Группы узлов** — groups whose JSON explicitly lists concrete outbound tags.
2. **Динамические группы** — actual `include`/`exclude` filters when recorded in JSON.
3. **Умные группы** — disabled; quarantine, new-node and health analytics are future work.
4. **Цепочки** — both native `type: chain` and actual proxy `detour`-linked hops
   (in r6 the Gemini chain copies are VLESS outbounds with `detour: "Стратегия"`).
5. **Составные группы** — selectors/URLTests referencing other groups plus nodes.

The primary entry point is **Группы адресов** (destination first), while
**Группы**, **Стратегии** and **DNS** provide component-first inspection.
The legacy `Пул A`–`Пул D` entries stay visible as real outbound groups;
the original dynamic generator distribution algorithm cannot be uniquely
reconstructed from generated JSON and is not implemented in the editor.

Categorization is a presentation projection only: a selector may also
appear in Strategies. This must not duplicate or alter configuration objects.
All source tags and original order are retained, including invisible U+2060
characters on generated Gemini chain tags. Undefined future group semantics
must never be fabricated from generated membership.
