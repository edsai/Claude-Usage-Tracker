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
    private static let sessionWindowSeconds: TimeInterval = 300   // 5 minutes
    private static let weeklyWindowSeconds: TimeInterval = 900    // 15 minutes

    /// Max sample buffer sizes (headroom beyond rolling window)
    private static let sessionMaxCapacity = 40
    private static let weeklyMaxCapacity = 60

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
           existingReset != usage.sessionResetTime {
            sessionHistory.clear()
        }
        sessionHistory.resetTime = usage.sessionResetTime
        sessionHistory.addSample(sessionSample)
        sessionHistories[profileId] = sessionHistory
        saveSessionHistory(sessionHistory, for: profileId)

        // Weekly history
        var weeklyHistory = loadWeeklyHistory(for: profileId)
        if let existingReset = weeklyHistory.resetTime,
           existingReset != usage.weeklyResetTime {
            weeklyHistory.clear()
        }
        weeklyHistory.resetTime = usage.weeklyResetTime
        weeklyHistory.addSample(weeklySample)
        weeklyHistories[profileId] = weeklyHistory
        saveWeeklyHistory(weeklyHistory, for: profileId)
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
        let history: UsageSampleHistory

        switch type {
        case .session:
            windowSeconds = Self.sessionWindowSeconds
            history = loadSessionHistory(for: profileId)
        case .weekly:
            windowSeconds = Self.weeklyWindowSeconds
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

        let percentageDelta = last.percentage - first.percentage
        let rate = percentageDelta / timeDelta  // percentage points per second

        // Rate is zero or negative — no activity
        guard rate > 0 else {
            return .noActivity
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

    // MARK: - Cleanup

    /// Clear all history for a profile (called when profile is deleted).
    func clearHistory(for profileId: UUID) {
        sessionHistories.removeValue(forKey: profileId)
        weeklyHistories.removeValue(forKey: profileId)
        defaults.removeObject(forKey: sessionKey(for: profileId))
        defaults.removeObject(forKey: weeklyKey(for: profileId))
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
        let history = loadHistory(key: sessionKey(for: profileId), maxCapacity: Self.sessionMaxCapacity)
        sessionHistories[profileId] = history
        return history
    }

    private func loadWeeklyHistory(for profileId: UUID) -> UsageSampleHistory {
        if let cached = weeklyHistories[profileId] {
            return cached
        }
        let history = loadHistory(key: weeklyKey(for: profileId), maxCapacity: Self.weeklyMaxCapacity)
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
