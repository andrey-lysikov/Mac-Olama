//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import IOKit

/// Machine profile: chip, memory, GPU. Read once at startup.
public struct HardwareProfile: Sendable, Equatable {
    public enum Tier: String, Sendable { case base, pro, max, ultra, unknown }

    public var chipName: String  // "Apple M4 Pro"
    public var family: Int?  // 1...5
    public var tier: Tier
    public var gpuCores: Int?
    public var memoryBytes: UInt64
    public var wiredLimitBytes: UInt64  // how much unified memory the GPU may take (estimate)
    /// Memory bandwidth in GB/s (table lookup by family/tier).
    public var bandwidthGBs: Double

    public var memoryGB: Int { Int(memoryBytes / (1024 * 1024 * 1024)) }

    /// `recommendedWorkingSetBytes` comes from Metal (`GPU.maxRecommendedWorkingSetBytes()` in OlamaMLX) when available.
    public static func current(recommendedWorkingSetBytes: Int? = nil) -> HardwareProfile {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let mem = sysctlUInt64("hw.memsize") ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let (family, tier) = parse(chip: chip)
        let wiredMB = sysctlUInt64("iogpu.wired_limit_mb") ?? 0
        let fallback = UInt64(Double(mem) * (mem > 36 * 1024 * 1024 * 1024 ? 0.75 : 0.67))
        let wired = recommendedWorkingSetBytes.map(UInt64.init) ?? (wiredMB > 0 ? wiredMB * 1024 * 1024 : fallback)
        return HardwareProfile(
            chipName: chip, family: family, tier: tier, gpuCores: gpuCoreCount(),
            memoryBytes: mem, wiredLimitBytes: wired, bandwidthGBs: bandwidth(family: family, tier: tier)
        )
    }

    static func parse(chip: String) -> (Int?, Tier) {
        let lower = chip.lowercased()
        var family: Int?
        if let r = lower.range(of: #"m(\d)"#, options: .regularExpression) {
            family = Int(lower[r].dropFirst())
        }
        let tier: Tier =
            lower.contains("ultra")
            ? .ultra : lower.contains("max") ? .max : lower.contains("pro") ? .pro : family != nil ? .base : .unknown
        return (family, tier)
    }

    /// Unified memory bandwidth table (GB/s) from Apple specs; M5 values need VERIFY.
    static func bandwidth(family: Int?, tier: Tier) -> Double {
        let table: [Int: [Tier: Double]] = [
            1: [.base: 68, .pro: 200, .max: 400, .ultra: 800],
            2: [.base: 100, .pro: 200, .max: 400, .ultra: 800],
            3: [.base: 100, .pro: 150, .max: 400, .ultra: 800],
            4: [.base: 120, .pro: 273, .max: 546, .ultra: 819],
            5: [.base: 153, .pro: 300, .max: 600, .ultra: 1200],
        ]
        // Physical constants, not something an API reports. A chip newer than the table borrows the newest known row
        // instead of dropping to a pessimistic default, so an unknown generation never looks slower than the last known one.
        guard let family, let newest = table.keys.max(), let row = table[family] ?? (family > newest ? table[newest] : nil) else {
            return 100
        }
        return row[tier] ?? row[.base] ?? 100
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
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// Estimate of how well a model will run on this machine.
public struct ModelFitReport: Sendable, Equatable {
    public enum Fit: Sendable { case comfortable, tight, no }
    public var fit: Fit
    public var stars: Int  // 1...5
    public var estimatedTokensPerSecond: Double
    public var memoryAfterLoadBytes: Int64
    public var warnings: [String]

    public static func evaluate(modelBytes: Int64, contextLength: Int?, hardware: HardwareProfile) -> ModelFitReport {
        // KV cache: ~0.125 MB/token for a 7–8B model with grouped-query attention in fp16, scaled by model size.
        // The earlier 0.5 MB/token (no GQA) made every model above ~5 GB look like it would not fit.
        let kvPerToken = 0.125 * 1024 * 1024 * max(0.3, Double(modelBytes) / (4.7 * 1024 * 1024 * 1024))
        let kv = Int64(kvPerToken * Double(min(contextLength ?? 8192, 8192)))
        let needed = modelBytes + kv + Int64(1.0 * 1024 * 1024 * 1024)
        let limit = Int64(hardware.wiredLimitBytes)
        let remaining = Int64(hardware.memoryBytes) - needed
        let tps = hardware.bandwidthGBs * 1e9 / Double(max(modelBytes, 1)) * 0.7
        var warnings: [String] = []
        let fit: Fit
        if needed > limit {
            fit = .no; warnings.append("not-enough-memory")
        } else if needed > Int64(Double(limit) * 0.85) {
            fit = .tight; warnings.append("tight-memory")
        } else {
            fit = .comfortable
        }
        let stars: Int
        switch (fit, tps) {
        case (.no, _): stars = 1
        case (.tight, _): stars = 2
        case (_, let t) where t >= 25: stars = 5
        case (_, let t) where t >= 15: stars = 4
        case (_, let t) where t >= 8: stars = 3
        default: stars = 2
        }
        return ModelFitReport(fit: fit, stars: stars, estimatedTokensPerSecond: tps, memoryAfterLoadBytes: remaining, warnings: warnings)
    }
}
