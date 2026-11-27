# iOS unsigned IPA: third-party re-signing compatibility

This branch removes runtime dependencies on the build author's signing team from the LX client.
The unsigned IPA still requires the receiving user's provisioning profile to grant the
Network Extension and a shared App Group to the host app and its Packet Tunnel extension.

## Required capabilities

- Main app and Packet Tunnel extension: packet-tunnel-provider entitlement.
- Main app and Packet Tunnel extension: at least one identical authorized
  com.apple.security.application-groups value.
- All embedded executables/frameworks/extensions must be consistently signed.
- iOS 15+ signatures must include DER entitlements (CodeDirectory special slot -7).
- Widget and File Provider need access to the same group for shared features.
- Signing Team ID and Bundle ID must be resolved from signed values, not Xcode defaults.

## Runtime behavior

- Missing or mismatched group: app stays open, with local-only settings/diagnostics.
  Starting or installing VPN gives an actionable error.
- A group is chosen only when shared with Packet Tunnel, accessible by the
  process, and either equal to the build-time preferred group or unambiguous.
- The real embedded Packet Tunnel Bundle ID is used for VPN registration.
- Existing iOS VPN profiles whose providerBundleIdentifier differs from the current
  extension are not silently reused: the user must reinstall the current VPN configuration.
- Widgets do not pick unrelated VPN tunnels via generic serverAddress.
- File Provider registration is skipped when there is no shared group.

## Known signing-time constraints

Runtime code cannot grant entitlements. Signing apps such as GBox must ensure
the provisioning profile permits the required entitlements. Code cannot repair an
unentitled signature, and VPN cannot run without these rights.

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
