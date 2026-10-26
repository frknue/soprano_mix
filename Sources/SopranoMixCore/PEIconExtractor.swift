import Foundation

/// Reads the icon of a Windows program (.exe/.dll) without Wine: the first
/// RT_GROUP_ICON resource and its RT_ICON images, reassembled as an .ico file that
/// `NSImage(data:)` reads.
public enum PEIconExtractor {
    /// Images per icon group beyond this are ignored.
    public static let maxEntries = 64
    /// Larger results are refused.
    public static let maxOutputBytes = 16 * 1024 * 1024

    private static let resourceTypeIcon = 3
    private static let resourceTypeGroupIcon = 14

    /// The first RT_GROUP_ICON of a Windows PE (.exe/.dll) assembled as .ico file data
    /// (every image of the group); nil when absent or malformed. Never traps on bad input.
    public static func icoData(fromPE data: Data) -> Data? {
        data.withUnsafeBytes { buffer -> Data? in
            guard let image = PEImage(bytes: buffer) else { return nil }
            return image.icoData()
        }
    }

    // MARK: - PE image

    private struct PEImage {
        let bytes: UnsafeRawBufferPointer
        /// File offset of the resource directory root.
        let resourceRoot: Int
        /// (virtualAddress, virtualSize, rawOffset, rawSize) per section.
        let sections: [(virtualAddress: Int, virtualSize: Int, rawOffset: Int, rawSize: Int)]

        init?(bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
            let reader = Reader(bytes: bytes)
            // DOS header: "MZ", e_lfanew at 0x3C.
            guard reader.u16(0) == 0x5A4D, let peOffset = reader.u32(0x3C) else { return nil }
            // "PE\0\0".
            guard reader.u32(peOffset) == 0x0000_4550 else { return nil }
            let coff = peOffset + 4
            guard let sectionCount = reader.u16(coff + 2),
                  let optionalSize = reader.u16(coff + 16)
            else { return nil }
            let optional = coff + 20
            guard let magic = reader.u16(optional) else { return nil }
            let directories: Int
            let directoryCountOffset: Int
            switch magic {
            case 0x10B: // PE32
                directoryCountOffset = optional + 92
                directories = optional + 96
            case 0x20B: // PE32+
                directoryCountOffset = optional + 108
                directories = optional + 112
            default:
                return nil
            }
            guard let directoryCount = reader.u32(directoryCountOffset), directoryCount > 2,
                  directories + 3 * 8 <= optional + optionalSize,
                  let resourceRVA = reader.u32(directories + 2 * 8),
                  let resourceSize = reader.u32(directories + 2 * 8 + 4),
                  resourceRVA > 0, resourceSize > 0
            else { return nil }

            var sections: [(virtualAddress: Int, virtualSize: Int, rawOffset: Int, rawSize: Int)] = []
            let table = optional + optionalSize
            for index in 0..<sectionCount {
                let header = table + index * 40
                guard let virtualSize = reader.u32(header + 8),
                      let virtualAddress = reader.u32(header + 12),
                      let rawSize = reader.u32(header + 16),
                      let rawOffset = reader.u32(header + 20)
                else { return nil }
                sections.append((virtualAddress, virtualSize, rawOffset, rawSize))
            }
            self.sections = sections
            guard let root = Self.offset(forRVA: resourceRVA, length: 16, sections: sections, fileSize: bytes.count) else { return nil }
            resourceRoot = root
        }

        /// The file offset of `length` bytes at `rva`, when they lie in one section's
        /// file data and inside the file.
        static func offset(
            forRVA rva: Int,
            length: Int,
            sections: [(virtualAddress: Int, virtualSize: Int, rawOffset: Int, rawSize: Int)],
            fileSize: Int
        ) -> Int? {
            guard rva >= 0, length >= 0 else { return nil }
            for section in sections {
                let extent = max(section.virtualSize, section.rawSize)
                guard rva >= section.virtualAddress, rva < section.virtualAddress + extent else { continue }
                let delta = rva - section.virtualAddress
                guard delta + length <= section.rawSize else { return nil }
                let offset = section.rawOffset + delta
                guard offset + length <= fileSize else { return nil }
                return offset
            }
            return nil
        }

        func icoData() -> Data? {
            let reader = Reader(bytes: bytes)
            // RT_GROUP_ICON → first name → first language.
            guard let groupNames = subdirectory(ofDirectory: resourceRoot, id: PEIconExtractor.resourceTypeGroupIcon),
                  let groupLanguages = firstSubdirectory(ofDirectory: groupNames),
                  let group = firstData(ofDirectory: groupLanguages)
            else { return nil }

            // GRPICONDIR: reserved, type (1 = icon), count; then 14-byte GRPICONDIRENTRYs.
            guard group.size >= 6,
                  reader.u16(group.offset) == 0,
                  reader.u16(group.offset + 2) == 1,
                  let declared = reader.u16(group.offset + 4), declared > 0
            else { return nil }
            let count = min(declared, PEIconExtractor.maxEntries)
            guard 6 + count * 14 <= group.size else { return nil }

            let iconNames = subdirectory(ofDirectory: resourceRoot, id: PEIconExtractor.resourceTypeIcon)
            var entries: [(header: Int, image: (offset: Int, size: Int))] = []
            var total = 6
            for index in 0..<count {
                let entry = group.offset + 6 + index * 14
                guard let id = reader.u16(entry + 12) else { return nil }
                guard let iconNames,
                      let languages = subdirectory(ofDirectory: iconNames, id: id),
                      let image = firstData(ofDirectory: languages),
                      image.size > 0
                else { continue }
                total += 16 + image.size
                guard total <= PEIconExtractor.maxOutputBytes else { return nil }
                entries.append((entry, image))
            }
            guard !entries.isEmpty else { return nil }

            var output = Data(capacity: total)
            output.appendLE16(0)
            output.appendLE16(1)
            output.appendLE16(entries.count)
            var imageOffset = 6 + entries.count * 16
            for entry in entries {
                // bWidth, bHeight, bColorCount, bReserved, wPlanes, wBitCount as in the group.
                output.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[entry.header..<(entry.header + 8)]))
                output.appendLE32(entry.image.size)
                output.appendLE32(imageOffset)
                imageOffset += entry.image.size
            }
            for entry in entries {
                output.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[entry.image.offset..<(entry.image.offset + entry.image.size)]))
            }
            return output
        }

        // MARK: Resource tree

        /// The entries of the resource directory at file offset `directory`:
        /// (isNamed, id, isDirectory, file offset of the target).
        private func entries(ofDirectory directory: Int) -> [(id: Int?, isDirectory: Bool, target: Int)]? {
            let reader = Reader(bytes: bytes)
            guard let named = reader.u16(directory + 12), let ids = reader.u16(directory + 14) else { return nil }
            var result: [(id: Int?, isDirectory: Bool, target: Int)] = []
            for index in 0..<(named + ids) {
                let entry = directory + 16 + index * 8
                guard let name = reader.u32(entry), let pointer = reader.u32(entry + 4) else { return nil }
                let isNamed = name & 0x8000_0000 != 0
                let isDirectory = pointer & 0x8000_0000 != 0
                let target = resourceRoot + (pointer & 0x7FFF_FFFF)
                guard target < bytes.count else { return nil }
                result.append((isNamed ? nil : name, isDirectory, target))
            }
            return result
        }

        private func subdirectory(ofDirectory directory: Int, id: Int) -> Int? {
            guard let list = entries(ofDirectory: directory),
                  let entry = list.first(where: { $0.id == id }), entry.isDirectory
            else { return nil }
            return entry.target
        }

        private func firstSubdirectory(ofDirectory directory: Int) -> Int? {
            guard let entry = entries(ofDirectory: directory)?.first, entry.isDirectory else { return nil }
            return entry.target
        }

        /// The data of the first entry of a language directory: (file offset, size).
        private func firstData(ofDirectory directory: Int) -> (offset: Int, size: Int)? {
            guard let entry = entries(ofDirectory: directory)?.first, !entry.isDirectory else { return nil }
            let reader = Reader(bytes: bytes)
            guard let rva = reader.u32(entry.target), let size = reader.u32(entry.target + 4),
                  size <= PEIconExtractor.maxOutputBytes,
                  let offset = Self.offset(forRVA: rva, length: size, sections: sections, fileSize: bytes.count)
            else { return nil }
            return (offset, size)
        }
    }

    // MARK: - Bounds-checked little-endian reads

    private struct Reader {
        let bytes: UnsafeRawBufferPointer

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - 2 else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }

        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
    }
}

private extension Data {
    mutating func appendLE16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE32(_ value: Int) {
        appendLE16(value)
        appendLE16(value >> 16)
    }
}
