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

    /// Memory that could be handed out right now (free, inactive and purgeable pages): a model competes with whatever
    /// is already running, so the wired limit alone says too little.
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
    /// Decodes a C-string buffer as UTF-8, cut at its terminator; only part of the buffer may be filled,
    /// and `String(cString:)` over an array is deprecated.
    init(cBuffer: [CChar]) {
        self = String(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Estimate of how well a model will run on this machine.
public struct ModelFitReport: Sendable, Equatable {
    public enum Fit: Sendable { case comfortable, tight, no }
    public var fit: Fit
    public var stars: Int  // 1...5
    public var estimatedTokensPerSecond: Double
    public var memoryAfterLoadBytes: Int64
    /// Split of `needed`, for the tooltip: weights, attention cache at the context used for the estimate, fixed headroom.
    public var weightsBytes: Int64 = 0
    public var kvBytes: Int64 = 0
    public var contextTokens: Int = 0
    public var warnings: [String]

    /// How much context the estimate assumes when the user has not chosen a window. A model may declare 260k, but the
    /// attention cache only grows with the conversation, and a chat that long is rare — the same 32k the reply budget
    /// is capped at. A window chosen in the models section is used as it is.
    public static let assumedContext = 32768
    /// Without a KV profile the cache is guessed from the model's size; that guess was calibrated on short chats and
    /// runs away at long ones, so it is asked about a shorter window.
    public static let assumedContextWithoutProfile = 8192

    /// `kvCache` comes from the model's own `config.json`; without it the old rule of thumb is used. `availableBytes` is
    /// what the machine can hand out right now (0 = do not take it into account). `chosenContext` is the window the
    /// model is set to run with, when there is one.
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
            // Rule of thumb: ~0.125 MB/token for a 7–8B model with grouped-query attention in fp16, scaled by model size.
            kv = Int64(0.125 * 1024 * 1024 * max(0.3, Double(modelBytes) / (4.7 * 1024 * 1024 * 1024)) * Double(context))
        }
        let needed = modelBytes + kv + Int64(1.0 * 1024 * 1024 * 1024)
        let limit = Int64(hardware.wiredLimitBytes)
        // What is free right now can be the tighter of the two: other apps hold memory the model would need.
        let free = availableBytes > 0 ? min(limit, Int64(availableBytes)) : limit
        let remaining = Int64(hardware.memoryBytes) - needed
        let tps = hardware.bandwidthGBs * 1e9 / Double(max(modelBytes, 1)) * 0.7
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
        let stars: Int
        switch (fit, tps) {
        case (.no, _): stars = 1
        case (.tight, _): stars = 2
        case (_, let t) where t >= 25: stars = 5
        case (_, let t) where t >= 15: stars = 4
        case (_, let t) where t >= 8: stars = 3
        default: stars = 2
        }
        return ModelFitReport(
            fit: fit, stars: stars, estimatedTokensPerSecond: tps, memoryAfterLoadBytes: remaining, weightsBytes: modelBytes,
            kvBytes: kv, contextTokens: context, warnings: warnings)
    }
}
