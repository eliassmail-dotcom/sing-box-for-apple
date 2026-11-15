# Config Studio 1.1 — semantic read-only release

## Goals

- Show the real, unchanged loaded sing-box/LX profile using user concepts: groups, strategies, address groups, route defaults, DNS policies, named DNS servers.
- Groups combine explicit nodes, referenced groups, and any actual include/exclude criteria present in source. Recursively resolve members, deduplicate names, detect cycles and broken links.
- Selector is an internal kernel construct. For user-facing strategies show manual or automatic selection and the real mode if known.
- N-tier failover is modeled separately from an outbound member list. Each tier has its own health gate (URL test, actual connection, or both), minimum healthy count, and quarantine policy.
- Implement pure two-pass tier selection: prefer all healthy tiers in priority order; only then permit quarantined nodes where their tier policy allows. No hidden DIRECT fallback.
- DNS policies are grouped by real DNS server, action, response handling, race/speculation. Every group retains exact original indices; grouping does not change evaluation order.
- Address groups are matched between route and DNS only on an identical subset of conditions. This is visualization and NOT proof of final runtime match when higher-priority rules apply.
- Current route.final and dns.final are separate; no automatic route-DNS following is claimed to be present in the kernel.
- The future editor model supports route to DNS association with explicit, inherit, automatic, and protected override modes. If no route mapping exists, explicitly expose that ambiguity.

## Actual kernel/source constraints

- URLTest least_test/failover/round_robin are supported by existing LX implementations; a selector with ordered outbounds is NOT itself a multi-tier failover strategy.
- Independent live URLTest latency and real TCP dial health must not be conflated.
- DNS rule actions and DNS server transport/detour are independent; matching a route does not automatically rewrite DNS rule tables in sing-box 1.14.
- DNS race/evaluate/match_response rules must not be blindly collapsed or reordered.
- Corporate Split DNS, SSO DIRECT, private LAN and SRS DIRECT bootstrap need protected overrides in the future writable compiler.

## Release boundary

1.1 reads JSON and provides an interactive, nonpersistent route-DNS association preview; it does NOT edit or apply the running config, generator, or Yandex Function. Runtime changes and a writable policy compiler require a separate release and an explicit migration.

## Verification

- SFUnitTests/StudioSemanticModelTests.swift: group recursion/cycles, strategy recognition, DNS cluster indices, exact match groups, route-DNS mapping, protected DNS, N-tier health and quarantine.
- Build iOS simulator with the LX core; sign/install test on physical iPhone before production use.

## Reuse priority

Keep sing-box/LX responsible for proxy execution, URLTest, DNS, rule-sets, OpenConnect and TUN. Swift semantic layer is a presenter plus pure draft policy calculations; do not invent a second network stack.