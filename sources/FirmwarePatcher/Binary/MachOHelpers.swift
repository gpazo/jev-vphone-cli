// MachOHelpers.swift — Mach-O parsing utilities for firmware patching.

import Foundation
import MachOKit

// MARK: - Segment/Section Info

/// Minimal segment info extracted from a Mach-O binary.
public struct MachOSegmentInfo: Sendable {
    public let name: String
    public let vmAddr: UInt64
    public let vmSize: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
}

/// Minimal section info extracted from a Mach-O binary.
public struct MachOSectionInfo: Sendable {
    public let segmentName: String
    public let sectionName: String
    public let address: UInt64
    public let size: UInt64
    public let fileOffset: UInt32
}

// MARK: - MachO Parser

/// Mach-O parsing utilities for kernel/firmware binary analysis.
public enum MachOParser {
    /// Parse all segments from a Mach-O binary in a Data buffer.
    public static func parseSegments(from data: Data) -> [MachOSegmentInfo] {
        var segments: [MachOSegmentInfo] = []
        guard data.count > 32 else { return segments }

        let magic = data.loadLE(UInt32.self, at: 0)
        guard magic == 0xFEED_FACF else { return segments } // MH_MAGIC_64

        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32 // sizeof(mach_header_64)

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = data.loadLE(UInt32.self, at: offset + 4)

            if cmd == 0x19 { // LC_SEGMENT_64
                let nameData = data[offset + 8 ..< offset + 24]
                let name = String(data: nameData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let vmAddr = data.loadLE(UInt64.self, at: offset + 24)
                let vmSize = data.loadLE(UInt64.self, at: offset + 32)
                let fileOff = data.loadLE(UInt64.self, at: offset + 40)
                let fileSize = data.loadLE(UInt64.self, at: offset + 48)

                segments.append(MachOSegmentInfo(
                    name: name, vmAddr: vmAddr, vmSize: vmSize,
                    fileOffset: fileOff, fileSize: fileSize
                ))
            }
            offset += Int(cmdsize)
        }
        return segments
    }

    /// Parse all sections from a Mach-O binary.
    /// Returns a dictionary keyed by "segment,section".
    public static func parseSections(from data: Data) -> [String: MachOSectionInfo] {
        var sections: [String: MachOSectionInfo] = [:]
        guard data.count > 32 else { return sections }

        let magic = data.loadLE(UInt32.self, at: 0)
        guard magic == 0xFEED_FACF else { return sections }

        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = data.loadLE(UInt32.self, at: offset + 4)

            if cmd == 0x19 { // LC_SEGMENT_64
                let segNameData = data[offset + 8 ..< offset + 24]
                let segName = String(data: segNameData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let nsects = data.loadLE(UInt32.self, at: offset + 64)

                var sectOff = offset + 72 // sizeof(segment_command_64) header
                for _ in 0 ..< nsects {
                    guard sectOff + 80 <= data.count else { break }
                    let sectNameData = data[sectOff ..< sectOff + 16]
                    let sectName = String(data: sectNameData, encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                    let addr = data.loadLE(UInt64.self, at: sectOff + 32)
                    let size = data.loadLE(UInt64.self, at: sectOff + 40)
                    let fileOff = data.loadLE(UInt32.self, at: sectOff + 48)

                    let key = "\(segName),\(sectName)"
                    sections[key] = MachOSectionInfo(
                        segmentName: segName, sectionName: sectName,
                        address: addr, size: size, fileOffset: fileOff
                    )
                    sectOff += 80
                }
            }
            offset += Int(cmdsize)
        }
        return sections
    }

    /// Convert a virtual address to a file offset using segment mappings.
    public static func vaToFileOffset(_ va: UInt64, segments: [MachOSegmentInfo]) -> Int? {
        for seg in segments {
            if va >= seg.vmAddr, va < seg.vmAddr + seg.vmSize {
                return Int(seg.fileOffset + (va - seg.vmAddr))
            }
        }
        return nil
    }

    /// Convert a virtual address to a file offset by parsing segments from data.
    public static func vaToFileOffset(_ va: UInt64, in data: Data) -> Int? {
        let segments = parseSegments(from: data)
        return vaToFileOffset(va, segments: segments)
    }

    /// Parse LC_SYMTAB information.
    /// Returns (symoff, nsyms, stroff, strsize) or nil.
    public static func parseSymtab(from data: Data) -> (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)? {
        guard data.count > 32 else { return nil }

        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = data.loadLE(UInt32.self, at: offset + 4)

            if cmd == 0x02 { // LC_SYMTAB
                let symoff = data.loadLE(UInt32.self, at: offset + 8)
                let nsyms = data.loadLE(UInt32.self, at: offset + 12)
                let stroff = data.loadLE(UInt32.self, at: offset + 16)
                let strsize = data.loadLE(UInt32.self, at: offset + 20)
                return (Int(symoff), Int(nsyms), Int(stroff), Int(strsize))
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    /// Find a symbol containing the given name fragment. Returns its virtual address.
    public static func findSymbol(containing fragment: String, in data: Data) -> UInt64? {
        guard let symtab = parseSymtab(from: data) else { return nil }

        for i in 0 ..< symtab.nsyms {
            let entryOff = symtab.symoff + i * 16 // sizeof(nlist_64)
            guard entryOff + 16 <= data.count else { break }

            let nStrx = data.loadLE(UInt32.self, at: entryOff)
            let nValue = data.loadLE(UInt64.self, at: entryOff + 8)

            guard nStrx < symtab.strsize, nValue != 0 else { continue }

            let strStart = symtab.stroff + Int(nStrx)
            guard strStart < data.count else { continue }

            // Read null-terminated string
            var strEnd = strStart
            while strEnd < data.count, strEnd < symtab.stroff + symtab.strsize {
                if data[strEnd] == 0 { break }
                strEnd += 1
            }

            if let name = String(data: data[strStart ..< strEnd], encoding: .ascii),
               name.contains(fragment)
            {
                return nValue
            }
        }
        return nil
    }
}
