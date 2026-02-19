//
//  UsageRateTracker.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-02-14.
//

import Foundation

/// Singleton service that collects usage samples and computes ETAs to 100%.
final class UsageRateTracker {
    static let shared = UsageRateTracker()

    /// Rolling window durations
    private static let sessionWindowSeconds: TimeInterval = 300     // 5 minutes
    private static let weeklyWindowSeconds: TimeInterval = 28800    // 8 hours

    /// Max sample buffer sizes (headroom beyond rolling window)
    private static let sessionMaxCapacity = 40
    private static let weeklyMaxCapacity = 200

    /// Minimum observation period before making determinations
    private static let sessionMinObservation: TimeInterval = 120    // 2 minutes
    private static let weeklyMinObservation: TimeInterval = 600     // 10 minutes

    /// Exponential weight half-lives for weighted regression
    private static let sessionHalfLife: TimeInterval = 120          // 2 minutes
    private static let weeklyHalfLife: TimeInterval = 7200          // 2 hours

    /// Per-profile histories keyed by profile UUID
    private var sessionHistories: [UUID: UsageSampleHistory] = [:]
    private var weeklyHistories: [UUID: UsageSampleHistory] = [:]

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Recording

    /// Record a sample from the latest usage fetch. Called on every refresh (~30s).
    func recordSample(usage: ClaudeUsage, profileId: UUID) {
        let now = Date()
        let sessionSample = UsageSample(percentage: usage.sessionPercentage, timestamp: now)
        let weeklySample = UsageSample(percentage: usage.weeklyPercentage, timestamp: now)

        // Session history
        var sessionHistory = loadSessionHistory(for: profileId)
        if let existingReset = sessionHistory.resetTime,
           !existingReset.isSameResetTime(as: usage.sessionResetTime) {
            sessionHistory.clear()
        }
        sessionHistory.resetTime = usage.sessionResetTime
        sessionHistory.addSample(sessionSample)
        sessionHistories[profileId] = sessionHistory
        saveSessionHistory(sessionHistory, for: profileId)

        // Weekly history
        var weeklyHistory = loadWeeklyHistory(for: profileId)
        if let existingReset = weeklyHistory.resetTime,
           !existingReset.isSameResetTime(as: usage.weeklyResetTime) {
            weeklyHistory.clear()
        }
        weeklyHistory.resetTime = usage.weeklyResetTime
        weeklyHistory.addSample(weeklySample)
        weeklyHistories[profileId] = weeklyHistory
        saveWeeklyHistory(weeklyHistory, for: profileId)

        // Record daily snapshot for weekly ETA views
        DailyConsumptionTracker.shared.recordIfNeeded(
            weeklyPercentage: usage.weeklyPercentage,
            resetTime: usage.weeklyResetTime,
            profileId: profileId
        )
    }

    // MARK: - ETA Estimation

    enum UsageType {
        case session
        case weekly
    }

    /// Estimate the time to reach 100% usage.
    func estimateTimeToFull(
        type: UsageType,
        currentPercentage: Double,
        resetTime: Date?,
        profileId: UUID
    ) -> UsageETAEstimate {
        // Already at limit
        if currentPercentage >= 100.0 {
            return .alreadyAtLimit
        }

        let windowSeconds: TimeInterval
        let minObservation: TimeInterval
        let halfLife: TimeInterval
        let history: UsageSampleHistory

        switch type {
        case .session:
            windowSeconds = Self.sessionWindowSeconds
            minObservation = Self.sessionMinObservation
            halfLife = Self.sessionHalfLife
            history = loadSessionHistory(for: profileId)
        case .weekly:
            windowSeconds = Self.weeklyWindowSeconds
            minObservation = Self.weeklyMinObservation
            halfLife = Self.weeklyHalfLife
            history = loadWeeklyHistory(for: profileId)
        }

        let windowSamples = history.samplesInWindow(seconds: windowSeconds)

        // Need at least 2 samples to compute a rate
        guard windowSamples.count >= 2,
              let first = windowSamples.first,
              let last = windowSamples.last else {
            return .calculating
        }

        let timeDelta = last.timestamp.timeIntervalSince(first.timestamp)
        guard timeDelta > 0 else {
            return .calculating
        }

        let hasEnoughData = timeDelta >= minObservation

        // Compute rate using exponentially-weighted linear regression
        guard let rate = computeWeightedRate(samples: windowSamples, halfLife: halfLife),
              rate > 0 else {
            return hasEnoughData ? .wontReachBeforeReset : .calculating
        }

        let remaining = 100.0 - currentPercentage
        let secondsToFull = remaining / rate
        let projectedFullDate = Date().addingTimeInterval(secondsToFull)

        // Check if projected 100% is past the reset time
        if let reset = resetTime, projectedFullDate > reset {
            return .wontReachBeforeReset
        }

        return .estimatedTime(projectedFullDate)
    }

    // MARK: - Weighted Linear Regression

    /// Compute the rate of change (percentage points per second) using
    /// exponentially-weighted least-squares linear regression.
    ///
    /// Each sample is weighted by `exp(-ln(2) * age / halfLife)` where age
    /// is measured from the most recent sample. This gives recent data more
    /// influence while still smoothing over the full window.
    ///
    /// Returns nil if there aren't enough distinct samples.
    private func computeWeightedRate(samples: [UsageSample], halfLife: TimeInterval) -> Double? {
        guard samples.count >= 2, let newest = samples.last else { return nil }

        let referenceTime = newest.timestamp.timeIntervalSince1970
        let ln2 = 0.693147180559945

        var sumW: Double = 0
        var sumWx: Double = 0
        var sumWy: Double = 0
        var sumWxx: Double = 0
        var sumWxy: Double = 0

        for sample in samples {
            let x = sample.timestamp.timeIntervalSince1970 - referenceTime  // negative or zero
            let y = sample.percentage
            let age = referenceTime - sample.timestamp.timeIntervalSince1970 // positive
            let w = exp(-ln2 * age / halfLife)

            sumW += w
            sumWx += w * x
            sumWy += w * y
            sumWxx += w * x * x
            sumWxy += w * x * y
        }

        // Weighted least-squares slope: β = (Σw·Σwxy - Σwx·Σwy) / (Σw·Σwxx - Σwx·Σwx)
        let denominator = sumW * sumWxx - sumWx * sumWx
        guard abs(denominator) > 1e-15 else { return nil }

        let slope = (sumW * sumWxy - sumWx * sumWy) / denominator
        return slope  // percentage points per second
    }

    // MARK: - Cleanup

    /// Clear all history for a profile (called when profile is deleted).
    func clearHistory(for profileId: UUID) {
        sessionHistories.removeValue(forKey: profileId)
        weeklyHistories.removeValue(forKey: profileId)
        defaults.removeObject(forKey: sessionKey(for: profileId))
        defaults.removeObject(forKey: weeklyKey(for: profileId))
        DailyConsumptionTracker.shared.clearHistory(for: profileId)
    }

    // MARK: - Persistence

    private func sessionKey(for profileId: UUID) -> String {
        "usageRateHistory_session_\(profileId.uuidString)"
    }

    private func weeklyKey(for profileId: UUID) -> String {
        "usageRateHistory_weekly_\(profileId.uuidString)"
    }

    private func loadSessionHistory(for profileId: UUID) -> UsageSampleHistory {
        if let cached = sessionHistories[profileId] {
            return cached
        }
        var history = loadHistory(key: sessionKey(for: profileId), maxCapacity: Self.sessionMaxCapacity)
        // Migrate capacity if loaded from older data
        if history.maxCapacity != Self.sessionMaxCapacity {
            history.maxCapacity = Self.sessionMaxCapacity
        }
        sessionHistories[profileId] = history
        return history
    }

    private func loadWeeklyHistory(for profileId: UUID) -> UsageSampleHistory {
        if let cached = weeklyHistories[profileId] {
            return cached
        }
        var history = loadHistory(key: weeklyKey(for: profileId), maxCapacity: Self.weeklyMaxCapacity)
        // Migrate capacity if loaded from older data
        if history.maxCapacity != Self.weeklyMaxCapacity {
            history.maxCapacity = Self.weeklyMaxCapacity
        }
        weeklyHistories[profileId] = history
        return history
    }

    private func loadHistory(key: String, maxCapacity: Int) -> UsageSampleHistory {
        guard let data = defaults.data(forKey: key),
              let history = try? decoder.decode(UsageSampleHistory.self, from: data) else {
            return UsageSampleHistory(maxCapacity: maxCapacity)
        }
        return history
    }

    private func saveSessionHistory(_ history: UsageSampleHistory, for profileId: UUID) {
        saveHistory(history, key: sessionKey(for: profileId))
    }

    private func saveWeeklyHistory(_ history: UsageSampleHistory, for profileId: UUID) {
        saveHistory(history, key: weeklyKey(for: profileId))
    }

    private func saveHistory(_ history: UsageSampleHistory, key: String) {
        if let data = try? encoder.encode(history) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Date Comparison Helper

private extension Date {
    /// Compare two reset times with a 60-second tolerance.
    /// The API fallback computes reset times from Date(), so they drift
    /// slightly on every refresh. A tolerance prevents false resets.
    func isSameResetTime(as other: Date) -> Bool {
        abs(self.timeIntervalSince(other)) < 60
    }
}
