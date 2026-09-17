// PatchComparisonTests.swift — Compare Swift patcher output against Python reference patches.
//
// Loads firmware binaries (pre-extracted raw payloads), runs Swift patchers,
// and verifies byte-exact match with the pre-generated Python reference JSON files.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Reference patch JSON format

private struct ReferencePatch: Decodable {
    let file_offset: Int
    let patch_bytes: String
    let patch_size: Int
    let description: String
    let component: String
}

private struct TXMDevReference: Decodable {
    let base: [ReferencePatch]
    let dev: [ReferencePatch]
}

// MARK: - Test helpers

private let baseDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ipsws/patch_refactor_input")

private func loadRawPayload(_ name: String) throws -> Data {
    let url = baseDir.appendingPathComponent("raw_payloads/\(name)")
    return try Data(contentsOf: url)
}

private func loadReference(_ name: String) throws -> [ReferencePatch] {
    let url = baseDir.appendingPathComponent("reference_patches/\(name).json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([ReferencePatch].self, from: data)
}

private func comparePatchRecords(
    swift swiftPatches: [PatchRecord],
    reference refPatches: [ReferencePatch],
    component: String
) {
    // Sort both by file_offset for stable comparison
    let sortedSwift = swiftPatches.sorted { $0.fileOffset < $1.fileOffset }
    let sortedRef = refPatches.sorted { $0.file_offset < $1.file_offset }

    // Compare counts
    if swiftPatches.count != refPatches.count {
        print("  ✗ \(component): patch count mismatch — Swift=\(swiftPatches.count), Python=\(refPatches.count)")

        // Show what Swift found
        print("    Swift patches:")
        for p in sortedSwift {
            print("      0x\(String(format: "%06X", p.fileOffset)) \(p.patchedBytes.hex) [\(p.patchID)]")
        }
        print("    Python patches:")
        for p in sortedRef {
            print("      0x\(String(format: "%06X", p.file_offset)) \(p.patch_bytes) [\(p.description)]")
        }
    }

    #expect(swiftPatches.count == refPatches.count,
            "\(component): patch count mismatch — Swift=\(swiftPatches.count), Python=\(refPatches.count)")

    let count = min(sortedSwift.count, sortedRef.count)
    var mismatches = 0
    for i in 0 ..< count {
        let s = sortedSwift[i]
        let r = sortedRef[i]
        let swiftHex = s.patchedBytes.hex

        if s.fileOffset != r.file_offset || swiftHex != r.patch_bytes {
            mismatches += 1
            print("  ✗ \(component) patch \(i): Swift=0x\(String(format: "%X", s.fileOffset)):\(swiftHex) vs Python=0x\(String(format: "%X", r.file_offset)):\(r.patch_bytes) [\(r.description)]")
        }

        #expect(s.fileOffset == r.file_offset,
                "\(component) patch \(i): offset mismatch — Swift=0x\(String(format: "%X", s.fileOffset)), Python=0x\(String(format: "%X", r.file_offset)) [\(r.description)]")
        #expect(swiftHex == r.patch_bytes,
                "\(component) patch \(i) @ 0x\(String(format: "%X", s.fileOffset)): bytes mismatch — Swift=\(swiftHex), Python=\(r.patch_bytes) [\(r.description)]")
    }

    if mismatches == 0, swiftPatches.count == refPatches.count {
        print("  ✓ \(component): all \(count) patches match exactly")
    }
}

// MARK: - AVPBooter Tests

struct AVPBooterComparisonTests {
    @Test func compareAVPBooter() throws {
        let data = try loadRawPayload("avpbooter.bin")
        let patcher = AVPBooterPatcher(data: data, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("avpbooter")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "avpbooter")
    }
}

// MARK: - iBoot Tests

struct IBSSComparisonTests {
    @Test func compareIBSS() throws {
        let data = try loadRawPayload("ibss.bin")
        let patcher = IBootPatcher(data: data, mode: .ibss, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("ibss")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "ibss")
    }
}

struct IBECComparisonTests {
    @Test func compareIBEC() throws {
        let data = try loadRawPayload("ibec.bin")
        let patcher = IBootPatcher(data: data, mode: .ibec, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("ibec")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "ibec")
    }
}

struct LLBComparisonTests {
    @Test func compareLLB() throws {
        let data = try loadRawPayload("llb.bin")
        let patcher = IBootPatcher(data: data, mode: .llb, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("llb")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "llb")
    }
}

// MARK: - TXM Tests

struct TXMComparisonTests {
    @Test func compareTXM() throws {
        let data = try loadRawPayload("txm.bin")
        let patcher = TXMPatcher(data: data, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("txm")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "txm")
    }
}

struct TXMDevComparisonTests {
    @Test func compareTXMDev() throws {
        let url = baseDir.appendingPathComponent("reference_patches/txm_dev.json")
        let jsonData = try Data(contentsOf: url)
        let ref = try JSONDecoder().decode(TXMDevReference.self, from: jsonData)

        let data = try loadRawPayload("txm.bin")
        let patcher = TXMDevPatcher(data: data, verbose: false)
        let swiftPatches = try patcher.findAll()

        // TXM dev includes base + dev patches
        let allRef = ref.base + ref.dev
        comparePatchRecords(swift: swiftPatches, reference: allRef, component: "txm_dev")
    }
}

// MARK: - Kernel Tests

struct KernelcacheComparisonTests {
    @Test func compareKernelcache() throws {
        let data = try loadRawPayload("kernelcache.bin")
        let patcher = KernelPatcher(data: data, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("kernelcache")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "kernelcache")
    }
}

// MARK: - JB Tests

struct IBSSJBComparisonTests {
    @Test func compareIBSSJB() throws {
        let data = try loadRawPayload("ibss.bin")
        let patcher = IBootJBPatcher(data: data, mode: .ibss, verbose: false)
        // IBootJBPatcher only adds JB-specific patches on top of base
        // We need to run findAll() first (base patches), then add JB patch
        patcher.patches = []
        patcher.patchSkipGenerateNonce()
        let refPatches = try loadReference("ibss_jb")
        comparePatchRecords(swift: patcher.patches, reference: refPatches, component: "ibss_jb")
    }
}

struct KernelcacheJBComparisonTests {
    @Test func compareKernelcacheJB() throws {
        let data = try loadRawPayload("kernelcache.bin")
        let patcher = KernelJBPatcher(data: data, verbose: false)
        let swiftPatches = try patcher.findAll()
        let refPatches = try loadReference("kernelcache_jb")
        comparePatchRecords(swift: swiftPatches, reference: refPatches, component: "kernelcache_jb")
    }
}
