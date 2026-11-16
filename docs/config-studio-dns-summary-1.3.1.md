# Config Studio 1.3.1 — compact DNS diagnostics (build 18)

## Problem

The prior DNS diagnostics screen ("Порядок обработки DNS") exposed a long, visually
noisy one-row-per-rule feed, even after moving it under "Дополнительно". The same
issue appeared with a filtered set of seven rules.

## UX fix

- Rename the screen **Обработка DNS** and show a concise overview, not all the rules.
- Present totals for DNS requests, rules marked with RACE, speculative requests,
  rules returning evaluated responses and any other actions. Show the involved DNS
  server tags without repeating dozens of near-identical evaluation records.
- The totals describe the **configuration**; they do not claim that every DNS
  lookup runs all rules.
- Add a single link **Посмотреть технические записи** to a second-level compact,
  searchable list that preserves the exact source rule numbers and original
  JSON access.
- Both the whole DNS policy and address-specific filtered subsets use the same
  summary view.
- Main DNS navigation and the Karing-style catalog remain unchanged.

## Safety

This is a presentation change only: no modifications to dns.rules, DNS server
selection, RACE semantics, routes, corporate DNS, SRS or the packet tunnel.
Existing priority assignment is a nonpersistent draft, not an applied policy.

## Checks

- SFUnitTests adds two focused tests for aggregated counts across all rules and
  across filtered conditions.
- CI verifies Libbox, XCTest, IPA archive and packaging on GitHub macOS runner.
