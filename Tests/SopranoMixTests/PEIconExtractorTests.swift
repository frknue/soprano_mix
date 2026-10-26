import AppKit
import Testing
@testable import SopranoMixCore

struct PEIconExtractorTests {
    // Resource section layout (offsets relative to the section start, RVA 0x1000, file 0x200).
    private let sectionRVA = 0x1000
    private let sectionFileOffset = 0x200
    private let icon1 = (0..<40).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
    private let icon2 = (0..<24).map { UInt8(truncatingIfNeeded: 200 &- $0) }

    private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        put16(&bytes, offset, value)
        put16(&bytes, offset + 2, value >> 16)
    }

    /// A resource directory header at `offset` followed by its id entries.
    private func directory(_ bytes: inout [UInt8], at offset: Int, entries: [(id: Int, target: Int, isDirectory: Bool)]) {
        put16(&bytes, offset + 14, entries.count)
        for (index, entry) in entries.enumerated() {
            let position = offset + 16 + index * 8
            put32(&bytes, position, entry.id)
            put32(&bytes, position + 4, entry.target | (entry.isDirectory ? 0x8000_0000 : 0))
        }
    }

    /// A PE32+ image with one RT_GROUP_ICON (id 1) of two RT_ICONs (ids 1, 2), group last.
    /// `groupCount` overrides the group's declared image count.
    private func makePE(pe32: Bool = false, groupCount: Int = 2) -> [UInt8] {
        var resource = [UInt8](repeating: 0, count: 0x110 + 6 + 2 * 14)
        // Root: RT_ICON (3) → 0x20, RT_GROUP_ICON (14) → 0x40.
        directory(&resource, at: 0x00, entries: [(3, 0x20, true), (14, 0x40, true)])
        // RT_ICON names 1 → 0x58, 2 → 0x70.
        directory(&resource, at: 0x20, entries: [(1, 0x58, true), (2, 0x70, true)])
        // RT_GROUP_ICON name 1 → 0x88.
        directory(&resource, at: 0x40, entries: [(1, 0x88, true)])
        // Language directories (0x409) → data entries.
        directory(&resource, at: 0x58, entries: [(0x409, 0xA0, false)])
        directory(&resource, at: 0x70, entries: [(0x409, 0xB0, false)])
        directory(&resource, at: 0x88, entries: [(0x409, 0xC0, false)])
        // Data entries: RVA, size.
        put32(&resource, 0xA0, sectionRVA + 0xD0); put32(&resource, 0xA4, icon1.count)
        put32(&resource, 0xB0, sectionRVA + 0xF8); put32(&resource, 0xB4, icon2.count)
        put32(&resource, 0xC0, sectionRVA + 0x110); put32(&resource, 0xC4, 6 + 2 * 14)
        // Images.
        resource.replaceSubrange(0xD0..<(0xD0 + icon1.count), with: icon1)
        resource.replaceSubrange(0xF8..<(0xF8 + icon2.count), with: icon2)
        // GRPICONDIR + two GRPICONDIRENTRYs.
        put16(&resource, 0x110, 0); put16(&resource, 0x112, 1); put16(&resource, 0x114, groupCount)
        let groupEntries: [(width: UInt8, height: UInt8, bits: Int, size: Int, id: Int)] = [
            (16, 16, 32, icon1.count, 1),
            (32, 32, 8, icon2.count, 2),
        ]
        for (index, entry) in groupEntries.enumerated() {
            let position = 0x116 + index * 14
            resource[position] = entry.width
            resource[position + 1] = entry.height
            put16(&resource, position + 4, 1)
            put16(&resource, position + 6, entry.bits)
            put32(&resource, position + 8, entry.size)
            put16(&resource, position + 12, entry.id)
        }

        var file = [UInt8](repeating: 0, count: sectionFileOffset)
        file[0] = 0x4D; file[1] = 0x5A // "MZ"
        put32(&file, 0x3C, 0x40)
        file[0x40] = 0x50; file[0x41] = 0x45 // "PE\0\0"
        let coff = 0x44
        put16(&file, coff, pe32 ? 0x14C : 0x8664)
        put16(&file, coff + 2, 1)
        let optionalSize = pe32 ? 96 + 16 * 8 : 112 + 16 * 8
        put16(&file, coff + 16, optionalSize)
        let optional = coff + 20
        put16(&file, optional, pe32 ? 0x10B : 0x20B)
        let directories = optional + (pe32 ? 96 : 112)
        put32(&file, directories - 4, 16)
        put32(&file, directories + 16, sectionRVA)
        put32(&file, directories + 20, resource.count)
        let section = optional + optionalSize
        for (index, character) in ".rsrc".utf8.enumerated() { file[section + index] = character }
        put32(&file, section + 8, resource.count)
        put32(&file, section + 12, sectionRVA)
        put32(&file, section + 16, resource.count)
        put32(&file, section + 20, sectionFileOffset)
        return file + resource
    }

    private func u16(_ data: Data, _ offset: Int) -> Int {
        Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
    }

    private func u32(_ data: Data, _ offset: Int) -> Int {
        u16(data, offset) | u16(data, offset + 2) << 16
    }

    @Test("one icon group with two images becomes a valid ico file")
    func extractsGroup() throws {
        for pe32 in [false, true] {
            let ico = try #require(PEIconExtractor.icoData(fromPE: Data(makePE(pe32: pe32))))
            #expect(ico.count == 6 + 2 * 16 + icon1.count + icon2.count)
            #expect(u16(ico, 0) == 0)
            #expect(u16(ico, 2) == 1)
            #expect(u16(ico, 4) == 2)

            // Entry 1: 16×16, 32 bpp.
            #expect(ico[6] == 16 && ico[7] == 16)
            #expect(u16(ico, 10) == 1)
            #expect(u16(ico, 12) == 32)
            #expect(u32(ico, 14) == icon1.count)
            #expect(u32(ico, 18) == 38)
            // Entry 2: 32×32, 8 bpp.
            #expect(ico[22] == 32 && ico[23] == 32)
            #expect(u16(ico, 28) == 8)
            #expect(u32(ico, 30) == icon2.count)
            #expect(u32(ico, 34) == 38 + icon1.count)

            #expect(Array(ico[38..<(38 + icon1.count)]) == icon1)
            #expect(Array(ico[(38 + icon1.count)...]) == icon2)
        }
    }

    @Test("every truncation of a valid image gives nil without trapping")
    func truncatedInput() {
        let full = makePE()
        for length in 0..<full.count {
            #expect(PEIconExtractor.icoData(fromPE: Data(full[0..<length])) == nil, "length \(length)")
        }
    }

    @Test("garbage, foreign files and lying counts give nil")
    func malformedInput() {
        #expect(PEIconExtractor.icoData(fromPE: Data()) == nil)
        #expect(PEIconExtractor.icoData(fromPE: Data(repeating: 0xFF, count: 4096)) == nil)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var bytes = (0..<1024).map { _ in UInt8.random(in: 0...255, using: &generator) }
            bytes[0] = 0x4D; bytes[1] = 0x5A
            _ = PEIconExtractor.icoData(fromPE: Data(bytes))
        }
        #expect(PEIconExtractor.icoData(fromPE: Data("MZ not a program".utf8)) == nil)
        #expect(PEIconExtractor.icoData(fromPE: Data(makePE(groupCount: 0))) == nil)
        #expect(PEIconExtractor.icoData(fromPE: Data(makePE(groupCount: 1000))) == nil)
    }

    @Test("corrupting single bytes never traps")
    func corruptedBytes() {
        let valid = makePE()
        for offset in stride(from: 0, to: valid.count, by: 3) {
            var corrupted = valid
            corrupted[offset] ^= 0xA5
            _ = PEIconExtractor.icoData(fromPE: Data(corrupted))
        }
    }

    @Test("a sliced Data value is read from its own start")
    func slicedData() {
        let padded = Data([0, 0, 0] + makePE())
        #expect(PEIconExtractor.icoData(fromPE: padded.dropFirst(3)) != nil)
    }
}
