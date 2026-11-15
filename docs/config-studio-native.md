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