# sing-box LX++ 1.14.9 b33 — candidate release notes

Status: **CONDITIONAL / DEVICE TEST REQUIRED**. This is not a verified fix for the two b32 runtime bugs.

## First Packet Tunnel start
- Reuse an existing On Demand or in-flight VPN connection rather than invoking `startVPNTunnel` twice.
- On a start failure with a fully disconnected session, wait briefly, reload NetworkExtension preferences, and retry **once** with the same validated configuration.
- Retain both first-attempt and retry failures in copyable diagnostics. Do not retry connecting/connected sessions.
- This mitigates session registration races but cannot repair missing Network Extension entitlements or a persistent iOS signing failure.

## Files on iPhone
- Enable Apple's native `On My iPhone > sing-box lx++` Documents location via
  `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`.
- Create a non-sensitive `About Files.txt` to make this Documents folder visible.
- This folder **does not** mirror the App Group Working directory or expose VPN secrets automatically.
- File Provider remains available only when the signed File Provider extension and host share a valid App Group and the immutable `NSExtensionFileProviderDocumentGroup` matches it.

## Signing profile support
- New `scripts/prepare_ipa_for_signer.py` accepts a registered signing App Group and creates a matching **unsigned** IPA before GBox/Feather signing.
- This step DOES NOT add App Group or Network Extension entitlements. The signing profile must authorize both; every nested .appex must be signed correctly.
- b32's structural preflight of the unsigned IPA did not validate the resulting signed IPA and should not be interpreted as on-device compatibility.

## Device acceptance criteria
1. Install/replace b32 with b33 using the same signing identity; first manual VPN start succeeds without a visible error.
2. Stop and restart VPN, test Control Center/On Demand, then reboot iOS and start again.
3. Files > On My iPhone shows the Documents folder and readable About Files.txt.
4. File Provider location is tested separately after the signed entitlements + static document group are verified to match.
5. On failure, capture copied VPN start diagnostics and the **signed IPA** (without the private key).
