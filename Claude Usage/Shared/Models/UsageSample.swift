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
    let maxCapacity: Int

    init(maxCapacity: Int = 40) {
        self.maxCapacity = maxCapacity
    }

    /// Append a sample and trim to max capacity
    mutating func addSample(_ sample: UsageSample) {
        samples.append(sample)
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
    /// Rate is zero or decreasing
    case noActivity
}
