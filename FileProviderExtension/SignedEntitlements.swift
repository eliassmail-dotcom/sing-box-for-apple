import Foundation
import CoreFoundation

/// Reads entitlements embedded in the running executable's code signature.
///
/// iOS provides no public API for runtime entitlement access (SecTaskCopyValueForEntitlement
/// is macOS-only), so this parses the Mach-O load commands and the embedded code-signature
/// blobs directly. Only public file structures are read - no private APIs are used.
///
/// Re-signing tools (GBox & friends) rewrite entitlements to match the signing
/// certificate's provisioning profile; this reader lets the app discover the
/// identifiers it was actually signed with, instead of build-time placeholders.
public enum SignedEntitlements {

    /// The value of `key` if it is an array of strings in the signed entitlements.
    public static func stringArray(_ key: String) -> [String] {
        if case .present(let value) = stringArrayResult(key, of: Bundle.main) { return value }
        return []
    }

    /// Typed outcome of reading a string-array entitlement: distinguishes a
    /// missing key, an empty array, an unexpected value type and an unreadable
    /// signature, so diagnostics never conflate ABSENT with UNKNOWN.
    public enum EntitlementReadResult {
        /// Key present with a non-empty array of strings.
        case present([String])
        /// Signature decoded, key absent.
        case absentKey
        /// Key present with an empty array.
        case emptyValue
        /// Key present with a value that is not an array of strings.
        case unexpectedType
        /// Signature unreadable (no XML, no valid DER).
        case unknown
    }

    /// Typed read of `key` from the current process entitlements.
    public static func stringArrayResult(_ key: String) -> EntitlementReadResult {
        stringArrayResult(key, of: Bundle.main)
    }

    /// Typed read of `key` from the given bundle's signed entitlements.
    public static func stringArrayResult(_ key: String, of bundle: Bundle) -> EntitlementReadResult {
        guard let dict = load(of: bundle) else { return .unknown }
        return stringArrayResult(key, in: dict)
    }

    /// Typed read of `key` from raw Mach-O image data (unit tests).
    internal static func stringArrayResult(_ key: String, machO data: Data) -> EntitlementReadResult {
        guard let dict = parse(data) else { return .unknown }
        return stringArrayResult(key, in: dict)
    }

    private static func stringArrayResult(_ key: String, in dict: [String: Any]) -> EntitlementReadResult {
        guard let any = dict[key] else { return .absentKey }
        guard let array = any as? [Any] else { return .unexpectedType }
        var strings: [String] = []
        for item in array {
            guard let string = item as? String else { return .unexpectedType }
            strings.append(string)
        }
        return strings.isEmpty ? .emptyValue : .present(strings)
    }

    /// Entitlements dictionary of the current process executable, or nil.
    public static func load() -> [String: Any]? {
        guard let url = Bundle.main.executableURL else { return nil }
        return load(executableAt: url)
    }

    /// Entitlements dictionary of the given bundle's executable, or nil.
    /// Used to inspect the peer binary (host app / packet-tunnel extension),
    /// whose signature may come from a different provisioning profile.
    public static func load(of bundle: Bundle) -> [String: Any]? {
        guard let url = bundle.executableURL else { return nil }
        return load(executableAt: url)
    }

    // Parsing a Mach-O reads the whole executable, and callers ask for the
    // same data repeatedly (app group resolution, signing diagnostics, peer
    // checks). Decoded results are cached per executable; only the decoded
    // dictionary is retained, never the mapped file data.
    private static let cacheLock = NSLock()
    private static var entitlementsCache: [String: [String: Any]?] = [:]
    private static var sourceDiagnosticsCache: [String: SourceDiagnostics] = [:]

    /// Incremented on every actual executable read+parse (unit tests only).
    internal static var debugParseCount = 0

    /// Clears the per-executable caches and counters (unit tests only).
    internal static func debugResetCacheForTests() {
        cacheLock.lock()
        entitlementsCache.removeAll()
        sourceDiagnosticsCache.removeAll()
        debugParseCount = 0
        cacheLock.unlock()
    }

    /// Cached read of an arbitrary executable path (unit tests).
    internal static func loadForTests(executableAt url: URL) -> [String: Any]? {
        load(executableAt: url)
    }

    /// Reads and caches the entitlements of an executable. A failed read is
    /// cached as nil: a missing or unreadable file is not retried on every call.
    private static func load(executableAt url: URL) -> [String: Any]? {
        let cacheKey = url.path
        cacheLock.lock()
        if let cached = entitlementsCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            cacheLock.lock()
            entitlementsCache[cacheKey] = nil
            cacheLock.unlock()
            return nil
        }
        let result = parse(data)
        cacheLock.lock()
        entitlementsCache[cacheKey] = result
        debugParseCount += 1
        cacheLock.unlock()
        return result
    }

    /// The value of `key` in the given bundle's signed entitlements.
    public static func stringArray(_ key: String, of bundle: Bundle) -> [String] {
        if case .present(let value) = stringArrayResult(key, of: bundle) { return value }
        return []
    }

    /// The provisioning profile may list App Group identifiers authorized for
    /// re-signing. This is ONLY a name-discovery fallback for DER-only signatures.
    /// Authorization is not an actual entitlement: each candidate must still
    /// succeed in FileManager.containerURL in the running process.
    public static func provisionedAppGroups(of bundle: Bundle) -> [String] {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return provisionedAppGroups(in: data)
    }

    /// Extracts an embedded XML property list from the CMS-wrapped profile.
    /// Malformed input yields no candidates; never treats the profile as rights.
    public static func provisionedAppGroups(in data: Data) -> [String] {
        guard data.count <= 3_000_000,
              let opening = data.range(of: Data("<plist".utf8)),
              let closing = data.range(of: Data("</plist>".utf8), in: opening.lowerBound..<data.endIndex),
              closing.upperBound > opening.lowerBound else {
            return []
        }
        let plist = data.subdata(in: opening.lowerBound..<closing.upperBound)
        guard let dictionary = (try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil
        )) as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return Array(Set(groups.filter { $0.hasPrefix("group.") })).sorted()
    }

    /// Parses the entitlements of a Mach-O image (thin or universal).
    /// Prefers the XML blob; falls back to the DER blob when XML is absent,
    /// so a DER-only signature is read rather than reported as "no rights".
    public static func parse(_ data: Data) -> [String: Any]? {
        let slice = arm64Slice(data) ?? data
        if let blob = entitlementsBlob(slice), blob.count > 8,
           let dict = (try? PropertyListSerialization.propertyList(
               from: blob.subdata(in: 8..<blob.count), options: [], format: nil
           )) as? [String: Any] {
            return dict
        }
        return derEntitlements(in: slice)
    }

    /// Entitlements decoded from the DER blob (slot 7) of a Mach-O image,
    /// or nil when the blob is absent or malformed. Never invents values:
    /// a key the signer did not encode stays absent from the result.
    public static func parseDEREntitlements(_ data: Data) -> [String: Any]? {
        derEntitlements(in: arm64Slice(data) ?? data)
    }

    private static func derEntitlements(in slice: Data) -> [String: Any]? {
        guard let blob = signatureBlob(slice, slot: 7), // CS_SLOT_DER_ENTITLEMENTS
              blob.count > 8,
              // Size limit is checked before the payload is copied into an array.
              blob.count - 8 <= DERPlist.maxPayloadBytes else { return nil }
        guard let canonical = DERPlist.parse(Array(blob.subdata(in: 8..<blob.count))) else {
            return nil
        }
        var result: [String: Any] = [:]
        for (key, value) in canonical {
            result[key] = DERPlist.box(value)
        }
        return result
    }

    /// Semantic comparison of the XML and DER entitlements of a Mach-O image.
    /// Returns nil when only one source is present (nothing to compare)
    /// or when either side cannot be decoded.
    public static func xmlDEREntitlementsMatch(_ data: Data) -> Bool? {
        let slice = arm64Slice(data) ?? data
        guard let xmlBlob = entitlementsBlob(slice), xmlBlob.count > 8,
              let xmlAny = (try? PropertyListSerialization.propertyList(
                  from: xmlBlob.subdata(in: 8..<xmlBlob.count), options: [], format: nil
              )) as? [String: Any] else { return nil }
        guard let derBlob = signatureBlob(slice, slot: 7), derBlob.count > 8,
              // Size limit is checked before the payload is copied into an array.
              derBlob.count - 8 <= DERPlist.maxPayloadBytes,
              let der = DERPlist.parse(Array(derBlob.subdata(in: 8..<derBlob.count))) else {
            return nil
        }
        guard let xml = DERPlist.canonicalize(xmlAny) else { return nil }
        return xml == der
    }

    /// Signing-source diagnostics for one executable: which entitlement blobs
    /// are present and decodable, which source a read would select, and
    /// whether XML and DER agree semantically. Losslessly typed so it can be
    /// rendered into a diagnostic report without re-parsing the binaries.
    public struct SourceDiagnostics: Equatable {
        public enum BlobStatus: String, Equatable { case absent, valid, invalid }
        public enum SelectedSource: String, Equatable { case xml, der, none }
        public enum MatchStatus: String, Equatable { case match, mismatch, unknown }
        public let xmlStatus: BlobStatus
        public let derStatus: BlobStatus
        public let selectedSource: SelectedSource
        public let xmlDERMatch: MatchStatus

        static let unreadable = SourceDiagnostics(
            xmlStatus: .absent, derStatus: .absent, selectedSource: .none, xmlDERMatch: .unknown
        )
    }

    /// Source diagnostics of the current process executable.
    public static func sourceDiagnostics() -> SourceDiagnostics {
        guard let url = Bundle.main.executableURL else { return SourceDiagnostics.unreadable }
        return sourceDiagnostics(executableAt: url)
    }

    /// Source diagnostics of the given bundle's executable.
    public static func sourceDiagnostics(of bundle: Bundle) -> SourceDiagnostics {
        guard let url = bundle.executableURL else { return SourceDiagnostics.unreadable }
        return sourceDiagnostics(executableAt: url)
    }

    /// Source diagnostics of raw Mach-O image data (unit tests).
    internal static func sourceDiagnostics(machO data: Data) -> SourceDiagnostics {
        diagnoseSources(of: arm64Slice(data) ?? data)
    }

    /// Cached per executable, mirroring the entitlements cache.
    private static func sourceDiagnostics(executableAt url: URL) -> SourceDiagnostics {
        let cacheKey = url.path
        cacheLock.lock()
        if let cached = sourceDiagnosticsCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let value: SourceDiagnostics
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            value = diagnoseSources(of: arm64Slice(data) ?? data)
            cacheLock.lock()
            debugParseCount += 1
            cacheLock.unlock()
        } else {
            value = SourceDiagnostics.unreadable
        }
        cacheLock.lock()
        sourceDiagnosticsCache[cacheKey] = value
        cacheLock.unlock()
        return value
    }

    /// Inspects the entitlement blobs of an already-sliced Mach-O image.
    private static func diagnoseSources(of slice: Data) -> SourceDiagnostics {
        var xml: [String: Any]? = nil
        let xmlStatus: SourceDiagnostics.BlobStatus
        if let blob = entitlementsBlob(slice), blob.count > 8 {
            xml = (try? PropertyListSerialization.propertyList(
                from: blob.subdata(in: 8..<blob.count), options: [], format: nil
            )) as? [String: Any]
            xmlStatus = xml != nil ? .valid : .invalid
        } else {
            xmlStatus = .absent
        }
        var der: [String: PListValue]? = nil
        let derStatus: SourceDiagnostics.BlobStatus
        if let blob = signatureBlob(slice, slot: 7), blob.count > 8 {
            if blob.count - 8 <= DERPlist.maxPayloadBytes,
               let parsed = DERPlist.parse(Array(blob.subdata(in: 8..<blob.count))) {
                der = parsed
                derStatus = .valid
            } else {
                derStatus = .invalid
            }
        } else {
            derStatus = .absent
        }
        let selectedSource: SourceDiagnostics.SelectedSource
        if xmlStatus == .valid {
            selectedSource = .xml
        } else if derStatus == .valid {
            selectedSource = .der
        } else {
            selectedSource = .none
        }
        let xmlDERMatch: SourceDiagnostics.MatchStatus
        if let xml, let der, let canonical = DERPlist.canonicalize(xml) {
            xmlDERMatch = canonical == der ? .match : .mismatch
        } else {
            xmlDERMatch = .unknown
        }
        return SourceDiagnostics(
            xmlStatus: xmlStatus, derStatus: derStatus,
            selectedSource: selectedSource, xmlDERMatch: xmlDERMatch
        )
    }

    // MARK: - Apple plist-in-DER entitlements
    //
    // Two dialects observed in real re-signed artifacts:
    //  zsign-class: root 0x70 [ version(0x02), dict(0xB0) [ pair* ] ]
    //  Feather:     root 0x31 [ pair* ]
    //  pair := 0x30 [ key(0x0C string), value ]
    //  value := 0x0C string | 0x01 bool | 0x02 integer | 0x30 array
    //
    // The parser is strict: any malformed, truncated, duplicated or unsupported
    // construct yields nil (UNKNOWN) instead of a partially decoded set of
    // rights, and bounded work protects the Network Extension process.

    /// Typed plist value for lossless comparison of XML and DER decodings.
    /// Bool and Int are distinct on purpose: `true` must not equal `1`.
    indirect enum PListValue: Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)
        case data(Data)
        case array([PListValue])
        case dictionary([String: PListValue])
    }

    private enum DERPlist {
        static let maxPayloadBytes = 256 * 1024
        static let maxElements = 8192
        static let maxDepth = 16

        struct Range {
            let tag: UInt8
            let start: Int
            let end: Int
        }

        struct Decoder {
            let bytes: [UInt8]
            var elements = 0

            /// Reads one tag-length-value element fully inside `limit`.
            mutating func tlv(at offset: Int, limit: Int) -> Range? {
                guard offset >= 0, offset + 2 <= limit, limit <= bytes.count else { return nil }
                let tag = bytes[offset]
                var off = offset + 1
                let first = bytes[off]
                var length = 0
                if first < 0x80 {
                    length = Int(first)
                    off += 1
                } else {
                    let num = Int(first & 0x7f)
                    guard num > 0, num <= 4, off + 1 + num <= limit else { return nil }
                    for i in 0..<num {
                        length = (length << 8) | Int(bytes[off + 1 + i])
                    }
                    off += 1 + num
                }
                guard off + length <= limit else { return nil }
                elements += 1
                guard elements <= maxElements else { return nil }
                return Range(tag: tag, start: off, end: off + length)
            }
        }

        /// Boxes a typed value back into the plain plist types used by callers.
        static func box(_ value: PListValue) -> Any {
            switch value {
            case .string(let s): return s
            case .bool(let b): return b
            case .int(let i): return i
            case .data(let d): return d
            case .array(let items): return items.map { box($0) }
            case .dictionary(let dict):
                var result: [String: Any] = [:]
                for (key, item) in dict { result[key] = box(item) }
                return result
            }
        }

        /// Converts a PropertyListSerialization result into comparable values.
        /// Returns nil for types with no plist-in-DER representation.
        static func canonicalize(_ any: [String: Any]) -> [String: PListValue]? {
            var result: [String: PListValue] = [:]
            for (key, value) in any {
                guard let canonical = canonicalize(value) else { return nil }
                result[key] = canonical
            }
            return result
        }

        private static func canonicalize(_ value: Any) -> PListValue? {
            switch value {
            case let v as String:
                return .string(v)
            case let v as Data:
                return .data(v)
            case let v as [Any]:
                var items: [PListValue] = []
                for item in v {
                    guard let canonical = canonicalize(item) else { return nil }
                    items.append(canonical)
                }
                return .array(items)
            case let v as [String: Any]:
                guard let dict = canonicalize(v) else { return nil }
                return .dictionary(dict)
            case let v as NSNumber:
                // A plist bool arrives as an NSNumber backed by CFBoolean;
                // distinguish it from real numbers so true != 1.
                if CFGetTypeID(v) == CFBooleanGetTypeID() {
                    return .bool(v.boolValue)
                }
                guard let i = v as? Int else { return nil } // no double support
                return .int(i)
            default:
                return nil
            }
        }

        static func parse(_ payload: [UInt8]) -> [String: PListValue]? {
            guard payload.count > 0, payload.count <= maxPayloadBytes else { return nil }
            var decoder = Decoder(bytes: payload)
            guard let root = decoder.tlv(at: 0, limit: payload.count),
                  root.end == payload.count else { return nil }
            let pairs: Range
            switch root.tag {
            case 0x70: // zsign-class: version integer + dict container
                guard let version = decoder.tlv(at: root.start, limit: root.end),
                      version.tag == 0x02, version.end - version.start == 1,
                      payload[version.start] == 1 else { return nil }
                guard let dict = decoder.tlv(at: version.end, limit: root.end),
                      dict.tag == 0xB0, dict.end == root.end else { return nil }
                pairs = dict
            case 0x31, 0x30: // Feather: pairs directly under the root
                pairs = Range(tag: 0x30, start: root.start, end: root.end)
            default:
                return nil
            }
            var result: [String: PListValue] = [:]
            var off = pairs.start
            while off < pairs.end {
                guard let pair = decoder.tlv(at: off, limit: pairs.end),
                      pair.tag == 0x30 else { return nil }
                guard let key = decoder.tlv(at: pair.start, limit: pair.end),
                      key.tag == 0x0C, key.end < pair.end,
                      let keyString = String(bytes: payload[key.start..<key.end], encoding: .utf8),
                      result[keyString] == nil else { return nil }
                guard let valueTLV = decoder.tlv(at: key.end, limit: pair.end),
                      valueTLV.end == pair.end else { return nil }
                guard let decoded = value(payload: payload, decoder: &decoder, tlv: valueTLV, depth: 1) else { return nil }
                result[keyString] = decoded
                off = pair.end
            }
            return result
        }

        /// Strict value decoding: rejects unsupported tags, oversized or
        /// truncated integers and arrays that do not fully parse. BOOLEAN
        /// deliberately accepts any single non-zero byte as true: the signers
        /// observed in the wild encode 0x01, and canonical DER 0xFF is not
        /// required for the dialects this parser supports.
        private static func value(payload: [UInt8], decoder: inout Decoder, tlv: Range, depth: Int) -> PListValue? {
            guard depth <= maxDepth else { return nil }
            switch tlv.tag {
            case 0x0C:
                guard let string = String(bytes: payload[tlv.start..<tlv.end], encoding: .utf8) else { return nil }
                return .string(string)
            case 0x01:
                guard tlv.end - tlv.start == 1 else { return nil }
                return .bool(payload[tlv.start] != 0)
            case 0x02:
                let length = tlv.end - tlv.start
                guard length > 0, length <= 8 else { return nil }
                // Sign-extend from the first byte (DER INTEGER is two's complement).
                var number = Int(truncatingIfNeeded: Int8(bitPattern: payload[tlv.start]))
                for i in (tlv.start + 1)..<tlv.end {
                    number = (number << 8) | Int(payload[i])
                }
                return .int(number)
            case 0x30:
                var items: [PListValue] = []
                var off = tlv.start
                while off < tlv.end {
                    guard let item = decoder.tlv(at: off, limit: tlv.end) else { return nil }
                    guard let decoded = value(payload: payload, decoder: &decoder, tlv: item, depth: depth + 1) else { return nil }
                    items.append(decoded)
                    off = item.end
                }
                return .array(items)
            default:
                return nil // unsupported tag: no partial interpretation
            }
        }
    }

    // MARK: - Mach-O

    /// For universal binaries, returns the arm64 slice (or the first slice as a fallback).
    private static func arm64Slice(_ data: Data) -> Data? {
        guard let magic = be32(data, 0) else { return nil }
        guard magic == 0xcafebabe || magic == 0xcafebabf else { return nil } // FAT_MAGIC / FAT_MAGIC_64
        guard let nfat = be32(data, 4), nfat > 0, nfat < 64 else { return nil }
        let entrySize = magic == 0xcafebabf ? 32 : 20
        var fallback: Data?
        for i in 0..<Int(nfat) {
            let base = 8 + i * entrySize
            guard let cputype = be32(data, base) else { continue }
            var offset = 0
            var size = 0
            if magic == 0xcafebabf {
                guard let off = be64(data, base + 8), let len = be64(data, base + 16) else { continue }
                offset = Int(off)
                size = Int(len)
            } else {
                guard let off = be32(data, base + 8), let len = be32(data, base + 12) else { continue }
                offset = Int(off)
                size = Int(len)
            }
            guard offset >= 0, size > 0, offset + size <= data.count else { continue }
            let slice = data.subdata(in: offset..<(offset + size))
            if cputype == 0x0100000C { // CPU_TYPE_ARM64
                return slice
            }
            if fallback == nil {
                fallback = slice
            }
        }
        return fallback
    }

    /// Locates an entitlement blob in a Mach-O code signature.
    /// CS_SuperBlob = magic (4) + length (4) + count (4) + count * CS_BlobIndex (8).
    private static func entitlementsBlob(_ data: Data) -> Data? {
        signatureBlob(data, slot: 5)
    }

    /// Useful for signing diagnostics; iOS 15+ expects the DER slot in signed apps.
    public static func hasDEREntitlements(_ data: Data) -> Bool {
        let slice = arm64Slice(data) ?? data
        return signatureBlob(slice, slot: 7) != nil
    }

    private static func signatureBlob(_ data: Data, slot: UInt32) -> Data? {
        guard let magic = le32(data, 0) else { return nil }
        let headerSize: Int
        let littleEndian: Bool
        switch magic {
        case 0xfeedfacf: // MH_MAGIC_64
            headerSize = 32
            littleEndian = true
        case 0xcffaedfe: // MH_CIGAM_64
            headerSize = 32
            littleEndian = false
        case 0xfeedface: // MH_MAGIC
            headerSize = 28
            littleEndian = true
        case 0xcefaedfe: // MH_CIGAM
            headerSize = 28
            littleEndian = false
        default:
            return nil
        }
        guard let ncmds = u32(data, 16, littleEndian), ncmds <= 4096 else { return nil }
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard let cmd = u32(data, offset, littleEndian),
                  let cmdsize = u32(data, offset + 4, littleEndian),
                  cmdsize >= 8, Int(cmdsize) <= data.count - offset else { return nil }
            if cmd == 0x1d { // LC_CODE_SIGNATURE
                guard cmdsize >= 16,
                      let dataoff = u32(data, offset + 8, littleEndian),
                      let datasize = u32(data, offset + 12, littleEndian),
                      Int(dataoff) <= data.count,
                      Int(datasize) <= data.count - Int(dataoff) else { return nil }
                return signatureBlob(inSuperBlobAt: Int(dataoff),
                                     maxSize: Int(datasize), slot: slot, of: data)
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    private static func signatureBlob(inSuperBlobAt start: Int,
                                      maxSize: Int, slot: UInt32, of data: Data) -> Data? {
        guard start >= 0, start <= data.count, maxSize >= 12,
              let magic = be32(data, start), magic == 0xfade0cc0,
              let totalLength = be32(data, start + 4),
              let count = be32(data, start + 8),
              totalLength >= 12,
              Int(totalLength) <= maxSize,
              Int(totalLength) <= data.count - start,
              Int(count) <= (Int(totalLength) - 12) / 8 else { return nil }

        let end = start + Int(totalLength)
        let indexEnd = start + 12 + Int(count) * 8
        for i in 0..<Int(count) {
            let entry = start + 12 + i * 8
            guard let entrySlot = be32(data, entry),
                  let relativeOffset = be32(data, entry + 4) else { return nil }
            guard entrySlot == slot else { continue }
            let blobStart = start + Int(relativeOffset)
            guard blobStart >= indexEnd, blobStart <= end - 8,
                  let blobMagic = be32(data, blobStart),
                  blobMagic == (slot == 5 ? 0xfade7171 : 0xfade7172),
                  let length = be32(data, blobStart + 4), length >= 8,
                  Int(length) <= end - blobStart else { return nil }
            return data.subdata(in: blobStart..<(blobStart + Int(length)))
        }
        return nil
    }

    // MARK: - Byte readers

    private static func be32(_ d: Data, _ o: Int) -> UInt32? { u32(d, o, false) }
    private static func le32(_ d: Data, _ o: Int) -> UInt32? { u32(d, o, true) }

    private static func u32(_ d: Data, _ o: Int, _ little: Bool) -> UInt32? {
        guard o >= 0, d.count >= o + 4 else { return nil }
        let b = [UInt8](d.subdata(in: o..<(o + 4)))
        if little {
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private static func be64(_ d: Data, _ o: Int) -> UInt64? {
        guard o >= 0, d.count >= o + 8 else { return nil }
        let b = [UInt8](d.subdata(in: o..<(o + 8)))
        var v: UInt64 = 0
        for byte in b {
            v = v << 8 | UInt64(byte)
        }
        return v
    }
}
