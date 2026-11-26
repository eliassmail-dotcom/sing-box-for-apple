import Foundation

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
        guard let dict = load() else { return [] }
        return dict[key] as? [String] ?? []
    }

    /// Entitlements dictionary of the current process executable, or nil.
    public static func load() -> [String: Any]? {
        guard let url = Bundle.main.executableURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Entitlements dictionary of the given bundle's executable, or nil.
    /// Used to inspect the peer binary (host app / packet-tunnel extension),
    /// whose signature may come from a different provisioning profile.
    public static func load(of bundle: Bundle) -> [String: Any]? {
        guard let url = bundle.executableURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// The value of `key` in the given bundle's signed entitlements.
    public static func stringArray(_ key: String, of bundle: Bundle) -> [String] {
        guard let dict = load(of: bundle) else { return [] }
        return dict[key] as? [String] ?? []
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
        var slice = data
        if let universal = arm64Slice(data) {
            slice = universal
        }
        if let blob = entitlementsBlob(slice), blob.count > 8,
           let dict = (try? PropertyListSerialization.propertyList(
               from: blob.subdata(in: 8..<blob.count), options: [], format: nil
           )) as? [String: Any] {
            return dict
        }
        return parseDEREntitlements(data)
    }

    /// Entitlements decoded from the DER blob (slot 7) of a Mach-O image,
    /// or nil when the blob is absent or malformed. Never invents values:
    /// a key the signer did not encode stays absent from the result.
    public static func parseDEREntitlements(_ data: Data) -> [String: Any]? {
        let slice = arm64Slice(data) ?? data
        guard let blob = signatureBlob(slice, slot: 7), // CS_SLOT_DER_ENTITLEMENTS
              blob.count > 8 else { return nil }
        return derPlist(Array(blob.subdata(in: 8..<blob.count)))
    }

    /// Semantic comparison of the XML and DER entitlements of a Mach-O image.
    /// Returns nil when only one source is present (nothing to compare)
    /// or when either side cannot be decoded.
    public static func xmlDEREntitlementsMatch(_ data: Data) -> Bool? {
        let slice = arm64Slice(data) ?? data
        guard let xmlBlob = entitlementsBlob(slice), xmlBlob.count > 8,
              let xml = (try? PropertyListSerialization.propertyList(
                  from: xmlBlob.subdata(in: 8..<xmlBlob.count), options: [], format: nil
              )) as? [String: Any] else { return nil }
        guard let der = parseDEREntitlements(data) else { return nil }
        return normalizedPlist(xml) == normalizedPlist(der)
    }

    /// Round-trips a dictionary through a binary plist so values from
    /// different decoders (PropertyListSerialization vs DER) compare with
    /// identical types.
    private static func normalizedPlist(_ dict: [String: Any]) -> [String: Any] {
        guard let data = try? PropertyListSerialization.data(
                fromPropertyList: dict, format: .binary, options: 0),
              let normalized = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any] else {
            return [:]
        }
        return normalized
    }

    // MARK: - Apple plist-in-DER entitlements
    //
    // Two dialects observed in real re-signed artifacts:
    //  zsign-class: root 0x70 [ version(0x02), dict(0xB0) [ pair* ] ]
    //  Feather:     root 0x31 [ pair* ]
    //  pair := 0x30 [ key(0x0C string), value ]
    //  value := 0x0C string | 0x01 bool | 0x02 integer | 0x30 array

    private struct DERRange {
        let tag: UInt8
        let start: Int
        let end: Int
    }

    /// Reads one tag-length-value element at `offset`; long-form lengths supported.
    private static func derTLV(_ bytes: [UInt8], _ offset: Int) -> DERRange? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var off = offset + 1
        let first = bytes[off]
        var length = 0
        if first < 0x80 {
            length = Int(first)
            off += 1
        } else {
            let num = Int(first & 0x7f)
            guard num > 0, num <= 4, off + 1 + num <= bytes.count else { return nil }
            for i in 0..<num {
                length = (length << 8) | Int(bytes[off + 1 + i])
            }
            off += 1 + num
        }
        guard length >= 0, off + length <= bytes.count else { return nil }
        return DERRange(tag: tag, start: off, end: off + length)
    }

    private static func derPlist(_ payload: [UInt8]) -> [String: Any]? {
        guard let root = derTLV(payload, 0) else { return nil }
        let pairs: [UInt8]
        switch root.tag {
        case 0x70: // zsign-class: version integer + dict container
            var dict: DERRange? = nil
            var sawVersion = false
            var off = root.start
            while off < root.end {
                guard let member = derTLV(payload, off), member.end <= root.end else { return nil }
                if member.tag == 0x02, !sawVersion {
                    sawVersion = true // version, value ignored
                } else if member.tag == 0xB0, dict == nil {
                    dict = member
                } else {
                    return nil
                }
                off = member.end
            }
            guard let dict else { return nil }
            pairs = Array(payload[dict.start..<dict.end])
        case 0x31, 0x30: // Feather: pairs directly under the root
            pairs = Array(payload[root.start..<root.end])
        default:
            return nil
        }
        var result: [String: Any] = [:]
        var off = 0
        while off < pairs.count {
            guard let pair = derTLV(pairs, off), pair.tag == 0x30 else { return nil }
            guard let key = derTLV(pairs, pair.start), key.tag == 0x0C,
                  let keyString = String(bytes: pairs[key.start..<key.end], encoding: .utf8) else {
                return nil
            }
            if key.end < pair.end, let value = derTLV(pairs, key.end) {
                result[keyString] = derValue(pairs, value)
            } else {
                result[keyString] = nil // key with no value
            }
            off = pair.end
        }
        return result
    }

    private static func derValue(_ bytes: [UInt8], _ tlv: DERRange) -> Any {
        switch tlv.tag {
        case 0x0C:
            return String(bytes: bytes[tlv.start..<tlv.end], encoding: .utf8) as Any
        case 0x01:
            return (tlv.end > tlv.start && bytes[tlv.start] != 0) as Any
        case 0x02:
            var value = 0
            for i in tlv.start..<tlv.end {
                value = (value << 8) | Int(bytes[i])
            }
            return value as Any
        case 0x30:
            var items: [Any] = []
            var off = tlv.start
            while off < tlv.end {
                guard let item = derTLV(bytes, off), item.end <= tlv.end else { break }
                items.append(derValue(bytes, item))
                off = item.end
            }
            return items as Any
        default:
            return Data(bytes[tlv.start..<tlv.end]) as Any
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
