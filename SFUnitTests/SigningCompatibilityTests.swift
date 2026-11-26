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

    // Minimal DER builders for the plist-in-DER dialects the parser supports.

    private func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var magnitude = length
        var bytes: [UInt8] = []
        while magnitude > 0 {
            bytes.insert(UInt8(magnitude & 0xFF), at: 0)
            magnitude >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    private func derTLV(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    private func derString(_ string: String) -> [UInt8] {
        derTLV(0x0C, Array(string.utf8))
    }

    private func derPair(_ key: String, _ value: [UInt8]) -> [UInt8] {
        derTLV(0x30, derString(key) + value)
    }

    private func sampleMachO(includeXML: Bool = true, includeDER: Bool = true,
                              xmlDict: [String: Any]? = nil,
                              xmlPayload: [UInt8]? = nil,
                              derPayload: [UInt8]? = nil) throws -> Data {
        let plist: Data
        if let raw = xmlPayload {
            plist = Data(raw)
        } else {
            plist = try PropertyListSerialization.data(fromPropertyList: xmlDict ?? [
                "com.apple.security.application-groups": ["group.example.shared"],
                "com.apple.developer.team-identifier": "EXAMPLE1234",
            ], format: .xml, options: 0)
        }
        let xml = big(0xfade7171) + big(UInt32(8 + plist.count)) + Array(plist)
        let derBody = derPayload ?? [UInt8(0x30), UInt8(0x00)]
        let der = big(0xfade7172) + big(UInt32(8 + derBody.count)) + derBody
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

    /// Real DER entitlements blob from a zsign-class CI signature (VT app, team AXSTP35NFJ).
    /// Root dialect: 0x70 [ version, 0xB0 dict [ pairs ] ].
    private static let zsignDERFixture: [UInt8] = {
        Array(Data(base64Encoded:
            "cIGOAgEBsIGIMD4MFmFwcGxpY2F0aW9uLWlkZW50aWZpZXIMJEFYU1RQMzVORkouYXBwLmFtZXRoeXN0NDE4NC5jb3JuMTgxNjAxDCNjb20uYXBwbGUuZGV2ZWxvcGVyLnRlYW0taWRlbnRpZmllcgwKQVhTVFAzNU5GSjATDA5nZXQtdGFzay1hbGxvdwEBAA=="
        )!)
    }()

    /// Real DER entitlements blob from a Feather signature (SFI b41, same team).
    /// Root dialect: 0x31 [ pairs ] (no version/dict wrapper).
    private static let featherDERFixture: [UInt8] = {
        Array(Data(base64Encoded:
            "MYIKJzA+DBZhcHBsaWNhdGlvbi1pZGVudGlmaWVyDCRBWFNUUDM1TkZKLmFwcC5hbWV0aHlzdDQxODQuY29ybjE4MTYwHQwPYXBzLWVudmlyb25tZW50DApwcm9kdWN0aW9uMDgMKGNvbS5hcHBsZS5kZXZlbG9wZXIuQ2xhc3NLaXQtZW52aXJvbm1lbnQwDAwKcHJvZHVjdGlvbjAsDB9jb20uYXBwbGUuZGV2ZWxvcGVyLmFwcGxlc2lnbmluMAkMB0RlZmF1bHQwKwwmY29tLmFwcGxlLmRldmVsb3Blci5hc3NvY2lhdGVkLWRvbWFpbnMMASowTQxIY29tLmFwcGxlLmRldmVsb3Blci5hdXRoZW50aWNhdGlvbi1zZXJ2aWNlcy5hdXRvZmlsbC1jcmVkZW50aWFsLXByb3ZpZGVyAQEBMEAMO2NvbS5hcHBsZS5kZXZlbG9wZXIuYXZmb3VuZGF0aW9uLm11bHRpdGFza2luZy1jYW1lcmEtYWNjZXNzAQEBMDIMLWNvbS5hcHBsZS5kZXZlbG9wZXIuY29yZW1lZGlhLmhscy5sb3ctbGF0ZW5jeQEBATBSDDVjb20uYXBwbGUuZGV2ZWxvcGVyLmRldmljZWNoZWNrLmFwcGF0dGVzdC1lbnZpcm9ubWVudDAZDAtkZXZlbG9wbWVudAwKcHJvZHVjdGlvbjAkDB9jb20uYXBwbGUuZGV2ZWxvcGVyLmdhbWUtY2VudGVyAQEBMCIMHWNvbS5hcHBsZS5kZXZlbG9wZXIuaGVhbHRoa2l0AQEBMDgMJGNvbS5hcHBsZS5kZXZlbG9wZXIuaGVhbHRoa2l0LmFjY2VzczAQDA5oZWFsdGgtcmVjb3JkczA2DDFjb20uYXBwbGUuZGV2ZWxvcGVyLmhlYWx0aGtpdC5iYWNrZ3JvdW5kLWRlbGl2ZXJ5AQEBMDgMM2NvbS5hcHBsZS5kZXZlbG9wZXIuaGVhbHRoa2l0LnJlY2FsaWJyYXRlLWVzdGltYXRlcwEBATAgDBtjb20uYXBwbGUuZGV2ZWxvcGVyLmhvbWVraXQBAQEwSgxGY29tLmFwcGxlLmRldmVsb3Blci5pY2xvdWQtY29udGFpbmVyLWRldmVsb3BtZW50LWNvbnRhaW5lci1pZGVudGlmaWVyczAAMDQMMGNvbS5hcHBsZS5kZXZlbG9wZXIuaWNsb3VkLWNvbnRhaW5lci1pZGVudGlmaWVyczAAMCgMI2NvbS5hcHBsZS5kZXZlbG9wZXIuaWNsb3VkLXNlcnZpY2VzDAEqMCcMI2NvbS5hcHBsZS5kZXZlbG9wZXIuaW4tYXBwLXBheW1lbnRzMAAwOww2Y29tLmFwcGxlLmRldmVsb3Blci5rZXJuZWwuZXh0ZW5kZWQtdmlydHVhbC1hZGRyZXNzaW5nAQEBMEAMO2NvbS5hcHBsZS5kZXZlbG9wZXIua2VybmVsLmluY3JlYXNlZC1kZWJ1Z2dpbmctbWVtb3J5LWxpbWl0AQEBMDYMMWNvbS5hcHBsZS5kZXZlbG9wZXIua2VybmVsLmluY3JlYXNlZC1tZW1vcnktbGltaXQBAQEwOAwzY29tLmFwcGxlLmRldmVsb3Blci5uZXR3b3JraW5nLkhvdHNwb3RDb25maWd1cmF0aW9uAQEBMC0MKGNvbS5hcHBsZS5kZXZlbG9wZXIubmV0d29ya2luZy5tdWx0aXBhdGgBAQEwgcAML2NvbS5hcHBsZS5kZXZlbG9wZXIubmV0d29ya2luZy5uZXR3b3JrZXh0ZW5zaW9uMIGMDBJhcHAtcHJveHktcHJvdmlkZXIMF2NvbnRlbnQtZmlsdGVyLXByb3ZpZGVyDBZwYWNrZXQtdHVubmVsLXByb3ZpZGVyDAlkbnMtcHJveHkMDGRucy1zZXR0aW5ncwwFcmVsYXkME3VybC1maWx0ZXItcHJvdmlkZXIMEGhvdHNwb3QtcHJvdmlkZXIwNQwmY29tLmFwcGxlLmRldmVsb3Blci5uZXR3b3JraW5nLnZwbi5hcGkwCwwJYWxsb3ctdnBuMC0MKGNvbS5hcHBsZS5kZXZlbG9wZXIubmV0d29ya2luZy53aWZpLWluZm8BAQEwQgwtY29tLmFwcGxlLmRldmVsb3Blci5uZmMucmVhZGVyc2Vzc2lvbi5mb3JtYXRzMBEMBE5ERUYMA1RBRwwEUEFDRTA7DCljb20uYXBwbGUuZGV2ZWxvcGVyLnBhc3MtdHlwZS1pZGVudGlmaWVyczAODAxBWFNUUDM1TkZKLiowHQwYY29tLmFwcGxlLmRldmVsb3Blci5zaXJpAQEBMDEMLGNvbS5hcHBsZS5kZXZlbG9wZXIuc3lzdGVtLWV4dGVuc2lvbi5pbnN0YWxsAQEBMDEMI2NvbS5hcHBsZS5kZXZlbG9wZXIudGVhbS1pZGVudGlmaWVyDApBWFNUUDM1TkZKMDYMMmNvbS5hcHBsZS5kZXZlbG9wZXIudWJpcXVpdHktY29udGFpbmVyLWlkZW50aWZpZXJzMAAwPwwvY29tLmFwcGxlLmRldmVsb3Blci51YmlxdWl0eS1rdnN0b3JlLWlkZW50aWZpZXIMDEFYU1RQMzVORkouKjBCDB5jb20uYXBwbGUuZGV2ZWxvcGVyLnVzZXItZm9udHMwIAwJYXBwLXVzYWdlDBNzeXN0ZW0taW5zdGFsbGF0aW9uMDgMM2NvbS5hcHBsZS5kZXZlbG9wZXIudXNlcm5vdGlmaWNhdGlvbnMuY29tbXVuaWNhdGlvbgEBATA5DDRjb20uYXBwbGUuZGV2ZWxvcGVyLnVzZXJub3RpZmljYXRpb25zLnRpbWUtc2Vuc2l0aXZlAQEBMCMMHmNvbS5hcHBsZS5kZXZlbG9wZXIud2VhdGhlcmtpdAEBATA2DB5jb20uYXBwbGUuZGV2ZWxvcGVyLndpZmktYXdhcmUwFAwHUHVibGlzaAwJU3Vic2NyaWJlMDgMM2NvbS5hcHBsZS5leHRlcm5hbC1hY2Nlc3Nvcnkud2lyZWxlc3MtY29uZmlndXJhdGlvbgEBATCBrAwlY29tLmFwcGxlLnNlY3VyaXR5LmFwcGxpY2F0aW9uLWdyb3VwczCBggwYZ3JvdXAuYTFhMzEyNmQ3NWVlOTBiZC4yDBhncm91cC5hMWEzMTI2ZDc1ZWU5MGJkLjEMGGdyb3VwLmExYTMxMjZkNzVlZTkwYmQuMwwYZ3JvdXAuYTFhMzEyNmQ3NWVlOTBiZC41DBhncm91cC5hMWEzMTI2ZDc1ZWU5MGJkLjQwEwwOZ2V0LXRhc2stYWxsb3cBAQAwFAwPaW50ZXItYXBwLWF1ZGlvAQEBMDkMFmtleWNoYWluLWFjY2Vzcy1ncm91cHMwHwwMQVhTVFAzNU5GSi4qDA9jb20uYXBwbGUudG9rZW4="
        )!)
    }()

    func testDEROnlySignatureIsReadFromDER() throws {
        let sample = try sampleMachO(includeXML: false, derPayload: Self.zsignDERFixture)
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertEqual(entitlements["application-identifier"] as? String,
                       "AXSTP35NFJ.app.amethyst4184.corn1816")
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String,
                       "AXSTP35NFJ")
        XCTAssertEqual(entitlements["get-task-allow"] as? Bool, false)
        XCTAssertTrue(SignedEntitlements.hasDEREntitlements(sample))
    }

    func testFeatherDERDialectIsDecoded() throws {
        let sample = try sampleMachO(includeXML: false, derPayload: Self.featherDERFixture)
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String,
                       "AXSTP35NFJ")
        let groups = try XCTUnwrap(entitlements["com.apple.security.application-groups"] as? [Any])
        XCTAssertEqual(groups.count, 5)
        XCTAssertTrue(groups.contains { ($0 as? String) == "group.a1a3126d75ee90bd.2" })
        let ne = try XCTUnwrap(entitlements["com.apple.developer.networking.networkextension"] as? [Any])
        XCTAssertTrue(ne.contains { ($0 as? String) == "packet-tunnel-provider" })
    }

    func testXMLIsPreferredOverDERWhenBothPresent() throws {
        // XML declares one team; the zsign fixture another: XML must win.
        let sample = try sampleMachO(includeXML: true, derPayload: Self.zsignDERFixture)
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String,
                       "EXAMPLE1234")
        XCTAssertNil(entitlements["application-identifier"])
    }

    func testXMLDERComparisonDetectsMismatchAndAbsence() throws {
        let mismatch = try sampleMachO(includeXML: true, derPayload: Self.zsignDERFixture)
        XCTAssertEqual(SignedEntitlements.xmlDEREntitlementsMatch(mismatch), false)

        let noDER = try sampleMachO(includeDER: false)
        XCTAssertNil(SignedEntitlements.xmlDEREntitlementsMatch(noDER))

        let derOnly = try sampleMachO(includeXML: false, derPayload: Self.zsignDERFixture)
        XCTAssertNil(SignedEntitlements.xmlDEREntitlementsMatch(derOnly))
    }

    func testMalformedDERBlobYieldsNoEntitlements() throws {
        let sample = try sampleMachO(includeXML: false, derPayload: [0x70, 0x81, 0xFF, 0x00])
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    // MARK: - DER edge cases (Peer Review №8, R4)

    func testEquivalentXMLAndDERCompareEqual() throws {
        let der = derTLV(0x31,
            derPair("com.apple.security.application-groups", derTLV(0x30, derString("group.example.shared")))
            + derPair("com.apple.developer.team-identifier", derString("EXAMPLE1234"))
        )
        let sample = try sampleMachO(derPayload: der)
        XCTAssertEqual(SignedEntitlements.xmlDEREntitlementsMatch(sample), true)
    }

    func testBooleanTrueIsNotIntegerOne() throws {
        // XML encodes Bool true; DER encodes INTEGER 1: the comparison must be false.
        let der = derTLV(0x31, derPair("flag", derTLV(0x02, [0x01])))
        let sample = try sampleMachO(xmlDict: ["flag": true], derPayload: der)
        XCTAssertEqual(SignedEntitlements.xmlDEREntitlementsMatch(sample), false)
    }

    func testCorruptXMLFallsBackToValidDER() throws {
        let sample = try sampleMachO(xmlPayload: Array("not a plist".utf8),
                                     derPayload: Self.zsignDERFixture)
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String,
                       "AXSTP35NFJ")
    }

    func testDuplicateKeyYieldsNoEntitlements() throws {
        let der = derTLV(0x31,
            derPair("k", derTLV(0x01, [0x00])) + derPair("k", derTLV(0x01, [0x00])))
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    func testTruncatedArrayYieldsNoEntitlements() throws {
        // Array claims 5 content bytes but the pair only carries 2.
        let truncatedArray: [UInt8] = [0x30, 0x05, 0x0C, 0x01]
        let der = derTLV(0x31, derPair("groups", truncatedArray))
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    func testUnknownValueTagYieldsNoEntitlements() throws {
        let der = derTLV(0x31, derPair("k", derTLV(0x55, [0x01])))
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    func testNegativeIntegerIsSignExtended() throws {
        // Two-byte DER INTEGER 0xFF0B is -245 in two's complement.
        let der = derTLV(0x31, derPair("n", derTLV(0x02, [0xFF, 0x0B])))
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertEqual(entitlements["n"] as? Int, -245)
    }

    func testExcessiveNestingDepthYieldsNoEntitlements() throws {
        var value = derString("x")
        for _ in 0..<20 { value = derTLV(0x30, value) }
        let der = derTLV(0x31, derPair("nested", value))
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    func testOversizedDERPayloadYieldsNoEntitlements() throws {
        let der = derTLV(0x31, [UInt8](repeating: 0, count: 256 * 1024 + 16))
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    func testElementCountLimitYieldsNoEntitlements() throws {
        var pairs: [UInt8] = []
        for i in 0..<3000 {
            pairs += derPair(String(format: "k%04d", i), derTLV(0x01, [0x00]))
        }
        let der = derTLV(0x31, pairs)
        let sample = try sampleMachO(includeXML: false, derPayload: der)
        XCTAssertNil(SignedEntitlements.parse(sample))
    }

    func testEmptyDERDictionaryParsesAsEmpty() throws {
        // Default DER payload is an empty root: valid, zero rights.
        let sample = try sampleMachO(includeXML: false)
        let entitlements = try XCTUnwrap(SignedEntitlements.parse(sample))
        XCTAssertTrue(entitlements.isEmpty)
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
