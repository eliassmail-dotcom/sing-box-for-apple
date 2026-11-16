import Foundation
import XCTest
@testable import Library

/// Pure synthetic Mach-O signatures: no developer account, keychain or provisioning needed.
final class SigningCompatibilityTests: XCTestCase {
    private func big(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
         UInt8((value >> 8) & 255), UInt8(value & 255)]
    }

    private func little(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 255)
        bytes[offset + 1] = UInt8((value >> 8) & 255)
        bytes[offset + 2] = UInt8((value >> 16) & 255)
        bytes[offset + 3] = UInt8((value >> 24) & 255)
    }

    private func sampleMachO(includeXML: Bool = true, includeDER: Bool = true) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "com.apple.security.application-groups": ["group.example.shared"],
            "com.apple.developer.team-identifier": "EXAMPLE1234",
        ], format: .xml, options: 0)
        let xml = big(0xfade7171) + big(UInt32(8 + plist.count)) + Array(plist)
        let der = big(0xfade7172) + big(10) + [UInt8(0x30), UInt8(0x00)]
        let slots: [(UInt32, [UInt8])] =
            (includeXML ? [(UInt32(5), xml)] : []) + (includeDER ? [(UInt32(7), der)] : [])

        var blob = big(0xfade0cc0)
        let payloadLength = slots.reduce(0) { $0 + $1.1.count }
        blob += big(UInt32(12 + slots.count * 8 + payloadLength))
        blob += big(UInt32(slots.count))
        var offset = 12 + slots.count * 8
        for (slot, payload) in slots {
            blob += big(slot)
            blob += big(UInt32(offset))
            offset += payload.count
        }
        for (_, payload) in slots { blob += payload }

        // Minimal 64-bit Mach-O header and one LC_CODE_SIGNATURE load command.
        var file = [UInt8](repeating: 0, count: 48)
        little(0xfeedfacf, into: &file, at: 0)
        little(1, into: &file, at: 16) // ncmds
        little(16, into: &file, at: 20) // sizeofcmds
        little(0x1d, into: &file, at: 32)
        little(16, into: &file, at: 36)
        little(48, into: &file, at: 40)
        little(UInt32(blob.count), into: &file, at: 44)
        return Data(file + blob)
    }

    func testReadsXMLAndDetectsDERSlot() throws {
        let sample = try sampleMachO()
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String],
                       ["group.example.shared"])
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String,
                       "EXAMPLE1234")
        XCTAssertTrue(SignedEntitlements.hasDEREntitlements(sample))
    }

    func testMissingDERIsReportedWithoutCrashing() throws {
        let sample = try sampleMachO(includeDER: false)
        XCTAssertNotNil(SignedEntitlements.parse(sample))
        XCTAssertFalse(SignedEntitlements.hasDEREntitlements(sample))
    }

    func testDEROnlyDoesNotInventXMLRights() throws {
        let sample = try sampleMachO(includeXML: false)
        XCTAssertNil(SignedEntitlements.parse(sample))
        XCTAssertTrue(SignedEntitlements.hasDEREntitlements(sample))
    }

    func testRejectsMalformedSuperblobCount() throws {
        var sample = [UInt8](try sampleMachO())
        // CS_SuperBlob count is at dataoff + 8, not dataoff + 4.
        sample.replaceSubrange(56..<60, with: big(1000))
        XCTAssertNil(SignedEntitlements.parse(Data(sample)))
    }

    func testRejectsTruncatedSignature() throws {
        var sample = [UInt8](try sampleMachO())
        sample.removeLast(10)
        XCTAssertNil(SignedEntitlements.parse(Data(sample)))
        XCTAssertFalse(SignedEntitlements.hasDEREntitlements(Data(sample)))
    }

    func testUnsignedBinaryHasNoEntitlements() {
        let unsigned = Data(repeating: 0, count: 48)
        XCTAssertNil(SignedEntitlements.parse(unsigned))
        XCTAssertFalse(SignedEntitlements.hasDEREntitlements(unsigned))
    }
    func testDEROnlySigningUsesMutuallyDeclaredAppGroupCandidate() {
        XCTAssertEqual(
            AppConfiguration.candidateAppGroups(
                ownSigned: [], peerSigned: [],
                hostConfigured: "group.example.shared",
                tunnelConfigured: "group.example.shared"
            ),
            ["group.example.shared"]
        )
    }

    func testMismatchNeverTrustsUnsignedPlistOverReadableSignature() {
        XCTAssertEqual(
            AppConfiguration.candidateAppGroups(
                ownSigned: ["group.example.host"],
                peerSigned: ["group.example.extension"],
                hostConfigured: "group.example.shared",
                tunnelConfigured: "group.example.shared"
            ),
            []
        )
    }

    func testMixedXMLAndDEROnlySigningUsesKnownSignedCandidates() {
        XCTAssertEqual(
            AppConfiguration.candidateAppGroups(
                ownSigned: ["group.example.actual"],
                peerSigned: [],
                hostConfigured: "group.example.stale",
                tunnelConfigured: "group.example.stale"
            ),
            ["group.example.actual"]
        )
    }

    func testAmbiguousGroupSetIsNotSilentlyReduced() {
        XCTAssertEqual(
            AppConfiguration.candidateAppGroups(
                ownSigned: ["group.example.b", "group.example.a"],
                peerSigned: ["group.example.a", "group.example.b"],
                hostConfigured: nil,
                tunnelConfigured: nil
            ),
            ["group.example.a", "group.example.b"]
        )
    }

    func testFallbackRejectsMissingOrDivergentDeclarations() {
        XCTAssertTrue(AppConfiguration.candidateAppGroups(
            ownSigned: [], peerSigned: [],
            hostConfigured: nil, tunnelConfigured: "group.example.x"
        ).isEmpty)
        XCTAssertTrue(AppConfiguration.candidateAppGroups(
            ownSigned: [], peerSigned: [],
            hostConfigured: "group.example.x", tunnelConfigured: "group.example.y"
        ).isEmpty)
    }

    func testExtractAuthorizedGroupNamesFromCMSWrappedProfile() throws {
        let profile = try PropertyListSerialization.data(fromPropertyList: [
            "Entitlements": [
                "com.apple.security.application-groups": [
                    "group.example.b", "group.example.a", "group.example.a"
                ],
            ],
        ], format: .xml, options: 0)
        let wrapped = Data([0x30, 0x82, 0x00, 0x00]) + profile + Data([0xff, 0xee])
        XCTAssertEqual(SignedEntitlements.provisionedAppGroups(in: wrapped),
                       ["group.example.a", "group.example.b"])
    }

    func testProvisioningPermissionsCannotOverrideContradictorySignedRights() {
        XCTAssertEqual(AppConfiguration.candidateAppGroups(
            ownSigned: ["group.example.host"],
            peerSigned: ["group.example.tunnel"],
            hostConfigured: nil,
            tunnelConfigured: nil,
            hostProvisioned: ["group.example.both"],
            tunnelProvisioned: ["group.example.both"]
        ), [])
    }

    func testDEROnlyProfilesSelectCommonAuthorizedCandidate() {
        XCTAssertEqual(AppConfiguration.candidateAppGroups(
            ownSigned: [], peerSigned: [],
            hostConfigured: "group.example.stale",
            tunnelConfigured: "group.example.stale",
            hostProvisioned: ["group.example.host", "group.example.shared"],
            tunnelProvisioned: ["group.example.shared", "group.example.tunnel"]
        ), ["group.example.shared"])
    }

    func testMalformedProvisioningDoesNotAuthorizeAnyGroup() {
        XCTAssertEqual(SignedEntitlements.provisionedAppGroups(in: Data([0x30, 0x00, 0xff])), [])
        XCTAssertEqual(SignedEntitlements.provisionedAppGroups(
            in: Data(repeating: 0, count: 3_000_001)
        ), [])
    }

    #if os(iOS)
    func testIsolatedLoopbackCredentialsArePersistentAndAuthenticated() throws {
        let first = try IsolatedCommandTransport.credentials()
        let second = try IsolatedCommandTransport.credentials()
        XCTAssertEqual(first.port, second.port)
        XCTAssertEqual(first.secret, second.secret)
        XCTAssertTrue((46_000...61_999).contains(Int(first.port)))
        XCTAssertEqual(Data(base64Encoded: first.secret)?.count, 32)
        XCTAssertTrue(IsolatedCommandTransport.validCredentials(
            port: NSNumber(value: first.port), secret: first.secret
        ))
    }

    func testIsolatedLoopbackNeverAcceptsEmptyOrShortSecret() {
        XCTAssertFalse(IsolatedCommandTransport.validCredentials(
            port: NSNumber(value: 50_000), secret: nil
        ))
        XCTAssertFalse(IsolatedCommandTransport.validCredentials(
            port: NSNumber(value: 50_000), secret: ""
        ))
        XCTAssertFalse(IsolatedCommandTransport.validCredentials(
            port: NSNumber(value: 50_000),
            secret: Data(repeating: 0, count: 31).base64EncodedString()
        ))
        XCTAssertFalse(IsolatedCommandTransport.validCredentials(
            port: NSNumber(value: 0),
            secret: Data(repeating: 1, count: 32).base64EncodedString()
        ))
        XCTAssertFalse(IsolatedCommandTransport.validCredentials(
            port: NSNumber(value: 63_000),
            secret: Data(repeating: 1, count: 32).base64EncodedString()
        ))
    }
    #endif

}
