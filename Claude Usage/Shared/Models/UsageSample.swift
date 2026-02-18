//
//  UsageSample.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-02-14.
//

import Foundation

/// A timestamped usage percentage snapshot
struct UsageSample: Codable {
    let percentage: Double
    let timestamp: Date
}

/// Rolling buffer of usage samples for a single metric (session or weekly)
struct UsageSampleHistory: Codable {
    private(set) var samples: [UsageSample] = []
    var resetTime: Date?
    var maxCapacity: Int

    /// Samples newer than this threshold (in seconds) are kept at full resolution.
    /// Older samples are downsampled into 5-minute buckets.
    private static let fullResolutionWindow: TimeInterval = 1800  // 30 minutes
    private static let downsampleBucketSize: TimeInterval = 300   // 5 minutes

    init(maxCapacity: Int = 40) {
        self.maxCapacity = maxCapacity
    }

    // MARK: - Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case samples, resetTime, maxCapacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        samples = try container.decodeIfPresent([UsageSample].self, forKey: .samples) ?? []
        resetTime = try container.decodeIfPresent(Date.self, forKey: .resetTime)
        maxCapacity = try container.decodeIfPresent(Int.self, forKey: .maxCapacity) ?? 40
    }

    /// Append a sample, compact older data, and trim to max capacity
    mutating func addSample(_ sample: UsageSample) {
        samples.append(sample)

        // Compact older samples into 5-minute buckets when buffer is large
        if samples.count > maxCapacity {
            compactOlderSamples(relativeTo: sample.timestamp)
        }

        // Hard trim if still over capacity after compaction
        if samples.count > maxCapacity {
            samples.removeFirst(samples.count - maxCapacity)
        }
    }

    /// Clear all samples (e.g. on period reset)
    mutating func clear() {
        samples.removeAll()
    }

    /// Return only samples within the rolling window (in seconds from now)
    func samplesInWindow(seconds: TimeInterval, from now: Date = Date()) -> [UsageSample] {
        let cutoff = now.addingTimeInterval(-seconds)
        return samples.filter { $0.timestamp >= cutoff }
    }

    // MARK: - Downsampling

    /// Compact samples older than the full-resolution window into 5-minute averaged buckets.
    private mutating func compactOlderSamples(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-Self.fullResolutionWindow)

        // Split into recent (full-res) and old (to be downsampled)
        let recentSamples = samples.filter { $0.timestamp >= cutoff }
        let oldSamples = samples.filter { $0.timestamp < cutoff }

        guard oldSamples.count > 1 else { return }

        // Group old samples into 5-minute buckets
        var buckets: [Int: [UsageSample]] = [:]
        for sample in oldSamples {
            let elapsed = cutoff.timeIntervalSince(sample.timestamp)
            let bucketIndex = Int(elapsed / Self.downsampleBucketSize)
            buckets[bucketIndex, default: []].append(sample)
        }

        // Average each bucket into a single sample
        var downsampled: [UsageSample] = []
        for (_, bucketSamples) in buckets.sorted(by: { $0.key > $1.key }) {
            let avgPercentage = bucketSamples.map(\.percentage).reduce(0, +) / Double(bucketSamples.count)
            let midTimestamp = bucketSamples[bucketSamples.count / 2].timestamp
            downsampled.append(UsageSample(percentage: avgPercentage, timestamp: midTimestamp))
        }

        // Reassemble: downsampled old + full-res recent
        samples = downsampled + recentSamples
    }
}

/// Estimated time to reaching 100% usage
enum UsageETAEstimate {
    /// Fewer than 2 samples in the rolling window
    case calculating
    /// Projected time to hit 100%
    case estimatedTime(Date)
    /// Projected 100% is after the reset time
    case wontReachBeforeReset
    /// Already at 100%
    case alreadyAtLimit
    /// Rate is zero or decreasing — no trend to show
    case noActivity

    var isNoActivity: Bool {
        if case .noActivity = self { return true }
        return false
    }
}
