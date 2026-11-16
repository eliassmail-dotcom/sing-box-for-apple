# iOS unsigned IPA: third-party re-signing compatibility

This branch removes runtime dependencies on the build author's signing team from the LX client.
The unsigned IPA still requires the receiving user's provisioning profile to grant
Network Extension rights to the host app and Packet Tunnel extension. A matching
App Group is required for FULL app/extension state sharing and the command socket;
it is no longer a hard requirement for a manual, isolated Packet Tunnel start.

## Required capabilities

- Main app and Packet Tunnel extension: packet-tunnel-provider entitlement.
- Full-featured mode: main app and Packet Tunnel extension need at least one
  identical authorized com.apple.security.application-groups value.
- All embedded executables/frameworks/extensions must be consistently signed.
- iOS 15+ signatures must include DER entitlements (CodeDirectory special slot -7).
- Widget and File Provider need access to the same group for shared features.
- Signing Team ID and Bundle ID must be resolved from signed values, not Xcode defaults.

## Runtime behavior

- Missing or mismatched group: the host app remains usable in process-local mode.
  Manual Dashboard starts pass validated configContent in startVPNTunnel(options:),
  and the extension keeps its own private last-good snapshot. VPN registration
  still requires the Network Extension entitlement. Some app-to-tunnel RPCs,
  live statistics, file sharing and first-launch widget starts need App Group and
  may be unavailable in isolated mode; isolated mode is not feature parity.
- For re-signers that omit the XML entitlements slot, candidates are also
  discovered from the embedded provisioning profiles or matching bundle declarations.
  Provisioning only supplies names: successful containerURL access determines
  usability per process. With readable conflicting signed entitlements or ambiguous
  multiple groups, do not invent a match.
- The real embedded Packet Tunnel Bundle ID is used for VPN registration.
- Existing iOS VPN profiles whose providerBundleIdentifier differs from the current
  extension are not silently reused: the user must reinstall the current VPN configuration.
- Widgets do not pick unrelated VPN tunnels via generic serverAddress.
- File Provider registration is skipped when there is no shared group.

## Known signing-time constraints

Runtime code cannot grant entitlements. Signing apps such as GBox must ensure
the provisioning profile permits the required Network Extension entitlement.
Code cannot repair an unentitled signature. A fully featured build also needs
identically authorized App Groups in the containing app and the tunnel extension.

The optional File Provider's Info.plist contains an
NSExtensionFileProviderDocumentGroup value derived at build time. Re-signers
must update it to the same group the extension is entitled to before signing,
or omit/disable that optional integration. This cannot be repaired by Swift
after code signing because modifying the plist would invalidate the signature.

iCloud Containers and Intents may require additional capabilities under a new
Team ID; they are not required for the core Packet Tunnel workflow. Do not attempt
to reuse a cloud container registered to another Apple Developer team.

## Verification on macOS (on a signed app)

1. Extract the IPA and locate Payload/*.app and its PlugIns/*.appex.
2. Run codesign --verify --strict --deep --verbose=2 on the signed app.
3. Inspect each app/extension with codesign -d --entitlements :-.
4. Compare main app/Packet Tunnel App Group sets and networkextension entitlements.
5. Ensure the shared group actually opens in the app; test VPN separately.
6. Confirm each signature includes DER entitlements (nonzero code signature slot -7).
7. Verify the Packet Tunnel signed CFBundleIdentifier equals the identifier
   saved in NETunnelProviderProtocol.providerBundleIdentifier.
8. Verify widget actions, file imports, File Provider and first/second startup.
9. Repeat with at least two distinct Team IDs using valid provisioning profiles.

Source-only changes are not proof of signed IPA compatibility. Run unit tests
and an iOS simulator build before declaring GO.

## GBox field diagnostic and isolated-mode test

1. Install and sign the same IPA consistently, including Packet Tunnel Extension.
2. Start from Dashboard first, not Control Center, to pass the current validated
   configuration directly in startVPNTunnel(options:).
3. If Network Extension is denied at install, inspect the actual signed entitlements
   of the host and tunnel. This cannot be fixed at runtime.
4. If manual VPN starts but the Dashboard cannot talk to the live command server,
   shared App Group rights are absent/mismatched; do not report full GO.
5. If a shared App Group is available, test Dashboard, reload, profile switching,
   Control Center cold-start and next-node commands, and private app/extension
   agreement. Verify with an exported signed IPA, not just unsigned CI output.
6. Never infer working signed entitlements from the unsigned IPA or from the
   provisioning profile alone. The iOS sandbox is the authority at runtime.
