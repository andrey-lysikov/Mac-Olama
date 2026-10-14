//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import IOKit

public struct HardwareProfile: Sendable, Equatable {
    public var chipName: String  // "Apple M4 Pro"
    public var gpuCores: Int?
    public var memoryBytes: UInt64
    public var wiredLimitBytes: UInt64  // GPU share of unified memory (estimate)

    public var memoryGB: Int { Int(memoryBytes / (1024 * 1024 * 1024)) }

    public static func current(recommendedWorkingSetBytes: Int? = nil) -> HardwareProfile {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let mem = sysctlUInt64("hw.memsize") ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let wiredMB = sysctlUInt64("iogpu.wired_limit_mb") ?? 0
        let fallback = UInt64(Double(mem) * (mem > 36 * 1024 * 1024 * 1024 ? 0.75 : 0.67))
        let wired = recommendedWorkingSetBytes.map(UInt64.init) ?? (wiredMB > 0 ? wiredMB * 1024 * 1024 : fallback)
        return HardwareProfile(
            chipName: chip, gpuCores: gpuCoreCount(), memoryBytes: mem, wiredLimitBytes: wired
        )
    }

    public static func availableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        var pageSize = vm_size_t()
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        return pages * UInt64(pageSize)
    }

    static func gpuCoreCount() -> Int? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

extension String {
    init(cBuffer: [CChar]) {
        self = String(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public struct ModelFitReport: Sendable, Equatable {
    public enum Fit: Sendable { case comfortable, tight, no }
    public var fit: Fit
    public var stars: Int
    public var memoryAfterLoadBytes: Int64
    public var weightsBytes: Int64 = 0
    public var kvBytes: Int64 = 0
    public var contextTokens: Int = 0
    public var warnings: [String]

    public static let assumedContext = 32768
    public static let assumedContextWithoutProfile = 8192

    public static func evaluate(
        modelBytes: Int64, contextLength: Int?, hardware: HardwareProfile, kvCache: KVCacheProfile? = nil,
        availableBytes: UInt64 = 0, chosenContext: Int? = nil
    ) -> ModelFitReport {
        let ceiling = kvCache != nil ? assumedContext : assumedContextWithoutProfile
        let context = chosenContext ?? min(contextLength ?? ceiling, ceiling)
        let kv: Int64
        if let kvCache {
            kv = kvCache.bytes(context: context)
        } else {
            // Rule of thumb: ~0.125 MB/token for 7–8B GQA fp16, scaled by size.
            kv = Int64(0.125 * 1024 * 1024 * max(0.3, Double(modelBytes) / (4.7 * 1024 * 1024 * 1024)) * Double(context))
        }
        let needed = modelBytes + kv + Int64(1.0 * 1024 * 1024 * 1024)
        let limit = Int64(hardware.wiredLimitBytes)
        // Free memory may be the tighter limit.
        let free = availableBytes > 0 ? min(limit, Int64(availableBytes)) : limit
        let remaining = Int64(hardware.memoryBytes) - needed
        var warnings: [String] = []
        let fit: Fit
        if needed > limit {
            fit = .no
            warnings.append("not-enough-memory")
        } else if needed > free {
            fit = .tight
            warnings.append("memory-busy")
        } else if needed > Int64(Double(limit) * 0.85) {
            fit = .tight
            warnings.append("tight-memory")
        } else {
            fit = .comfortable
        }
        let stars =
            switch fit {
            case .no: 1
            case .tight: 2
            case .comfortable: 3
            }
        return ModelFitReport(
            fit: fit, stars: stars, memoryAfterLoadBytes: remaining, weightsBytes: modelBytes,
            kvBytes: kv, contextTokens: context, warnings: warnings)
    }
}
