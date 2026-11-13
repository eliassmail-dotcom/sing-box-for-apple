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

    /// Parses the XML entitlements blob out of a Mach-O image (thin or universal).
    public static func parse(_ data: Data) -> [String: Any]? {
        var slice = data
        if let universal = arm64Slice(data) {
            slice = universal
        }
        guard let blob = entitlementsBlob(slice) else { return nil }
        guard blob.count > 8 else { return nil }
        let payload = blob.subdata(in: 8..<blob.count)
        return (try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil)) as? [String: Any]
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

    /// Locates the entitlements blob within a thin Mach-O slice.
    private static func entitlementsBlob(_ data: Data) -> Data? {
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
        case 0xfeedfeed: // MH_MAGIC
            headerSize = 28
            littleEndian = true
        default:
            return nil
        }
        guard let ncmds = u32(data, 16, littleEndian), ncmds < 4096 else { return nil }
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard let cmd = u32(data, offset, littleEndian),
                  let cmdsize = u32(data, offset + 4, littleEndian),
                  cmdsize >= 8 else { return nil }
            if cmd == 0x1d { // LC_CODE_SIGNATURE (linkedit_data_command)
                guard let dataoff = u32(data, offset + 8, littleEndian) else { return nil }
                return entitlementsBlob(inSuperBlobAt: Int(dataoff), of: data)
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    /// Finds the entitlements blob (slot 5) inside the embedded-signature superblob.
    private static func entitlementsBlob(inSuperBlobAt start: Int, of data: Data) -> Data? {
        guard let magic = be32(data, start), magic == 0xfade0cc0 else { return nil } // CSMAGIC_EMBEDDED_SIGNATURE
        guard let count = be32(data, start + 4), count < 64 else { return nil }
        for i in 0..<Int(count) {
            let entry = start + 8 + i * 8
            guard let slot = be32(data, entry), let blobOffset = be32(data, entry + 4) else { continue }
            guard slot == 5 else { continue } // CSSLOT_ENTITLEMENTS
            let blobStart = start + Int(blobOffset)
            guard let blobMagic = be32(data, blobStart), blobMagic == 0xfade7171 else { return nil } // CSMAGIC_EMBEDDED_ENTITLEMENTS
            guard let blobLength = be32(data, blobStart + 4), blobLength >= 8 else { return nil }
            let end = blobStart + Int(blobLength)
            guard end <= data.count else { return nil }
            return data.subdata(in: blobStart..<end)
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
