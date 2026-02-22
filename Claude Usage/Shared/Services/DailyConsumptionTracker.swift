//
//  DailyConsumptionTracker.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-02-18.
//

import Foundation

/// A snapshot of weekly usage at the start of a calendar day
struct DailySnapshot: Codable, Equatable {
    let date: Date                // midnight of that day (user's TZ)
    let weeklyPercentageAtStart: Double
    let dayOfWeek: Int            // 1=Mon ... 7=Sun
}

/// Result for a single day's consumption delta
struct DailyDelta {
    let label: String        // e.g. "Mon", "Tue"
    let delta: Double        // percentage points consumed that day
    let isToday: Bool
    let isFuture: Bool
}

/// Singleton service that tracks the weekly % at the start of each calendar day per profile.
/// Used to compute daily deltas, projections, and budget information for weekly ETA views.
final class DailyConsumptionTracker {
    static let shared = DailyConsumptionTracker()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Recording

    /// Record today's snapshot if not already recorded for this calendar day.
    /// Clears history when a new weekly reset is detected.
    func recordIfNeeded(
        weeklyPercentage: Double,
        resetTime: Date?,
        profileId: UUID
    ) {
        var snapshots = loadSnapshots(for: profileId)
        let now = Date()
        let todayMidnight = now.startOfDay()

        // Detect weekly reset: if we have snapshots and the reset time changed significantly,
        // or the current percentage dropped well below what we had before, clear history
        if let lastSnapshot = snapshots.last {
            // If percentage dropped by more than 5% from what we had, it's likely a reset
            let lastRecordedPercentage = lastSnapshot.weeklyPercentageAtStart
            if weeklyPercentage < lastRecordedPercentage - 5.0 && !snapshots.isEmpty {
                snapshots.removeAll()
            }
        }

        // Check if we already have a snapshot for today
        if let lastSnapshot = snapshots.last,
           lastSnapshot.date == todayMidnight {
            return // Already recorded today
        }

        let snapshot = DailySnapshot(
            date: todayMidnight,
            weeklyPercentageAtStart: weeklyPercentage,
            dayOfWeek: now.dayOfWeekIndex()
        )
        snapshots.append(snapshot)

        // Keep at most 8 days of snapshots (7 days + today buffer)
        if snapshots.count > 8 {
            snapshots.removeFirst(snapshots.count - 8)
        }

        saveSnapshots(snapshots, for: profileId)
    }

    // MARK: - Daily Deltas

    /// Compute daily consumption deltas for Mon-Sun of the current week.
    /// Returns actual deltas for past days, partial for today, projected average for future.
    func dailyDeltas(
        currentPercentage: Double,
        resetTime: Date?,
        profileId: UUID
    ) -> [DailyDelta] {
        let snapshots = loadSnapshots(for: profileId)
        let now = Date()
        let todayIndex = now.dayOfWeekIndex() // 1=Mon...7=Sun
        let avgPace = averageDailyPace(currentPercentage: currentPercentage, profileId: profileId)

        var deltas: [DailyDelta] = []

        // Build a lookup of snapshots by dayOfWeek
        var snapshotsByDay: [Int: DailySnapshot] = [:]
        for snapshot in snapshots {
            snapshotsByDay[snapshot.dayOfWeek] = snapshot
        }

        // Generate day labels for Mon(1) through Sun(7)
        let calendar = Calendar.current
        let dayLabels = generateDayLabels()

        for dayIdx in 1...7 {
            let label = dayLabels[dayIdx - 1]

            if dayIdx < todayIndex {
                // Past day: compute actual delta from consecutive snapshots
                if let daySnapshot = snapshotsByDay[dayIdx],
                   let nextSnapshot = snapshotsByDay[dayIdx + 1] ?? (dayIdx + 1 == todayIndex ? nil : nil) {
                    let delta = nextSnapshot.weeklyPercentageAtStart - daySnapshot.weeklyPercentageAtStart
                    deltas.append(DailyDelta(label: label, delta: max(0, delta), isToday: false, isFuture: false))
                } else if let daySnapshot = snapshotsByDay[dayIdx] {
                    // Use next available snapshot or today's data
                    let nextDay = findNextSnapshotPercentage(after: dayIdx, snapshots: snapshotsByDay, todayIndex: todayIndex, currentPercentage: currentPercentage)
                    let delta = nextDay - daySnapshot.weeklyPercentageAtStart
                    deltas.append(DailyDelta(label: label, delta: max(0, delta), isToday: false, isFuture: false))
                } else {
                    // No data for this day, use average
                    deltas.append(DailyDelta(label: label, delta: avgPace, isToday: false, isFuture: false))
                }
            } else if dayIdx == todayIndex {
                // Today: partial day
                let todayDelta = todayConsumption(currentPercentage: currentPercentage, profileId: profileId)
                deltas.append(DailyDelta(label: label, delta: todayDelta, isToday: true, isFuture: false))
            } else {
                // Future day: projected average
                deltas.append(DailyDelta(label: label, delta: avgPace, isToday: false, isFuture: true))
            }
        }

        return deltas
    }

    // MARK: - Projections

    /// Projected weekly percentage at reset, based on current pace
    func projectedAtReset(
        currentPercentage: Double,
        resetTime: Date?,
        profileId: UUID
    ) -> Double {
        let now = Date()
        guard let resetTime = resetTime, resetTime > now else {
            return currentPercentage
        }

        let avgPace = averageDailyPace(currentPercentage: currentPercentage, profileId: profileId)
        let remainingDays = resetTime.timeIntervalSince(now) / 86400.0
        let projected = currentPercentage + remainingDays * avgPace

        return min(projected, 100.0)
    }

    /// Average daily consumption rate, blending the smoothed real-time rate from
    /// UsageRateTracker with the snapshot-based daily average.  Early in the window
    /// (few snapshots) the smoothed rate dominates; after ~3 days the daily average
    /// takes over since it captures full-day patterns (sleep, work, etc.).
    func averageDailyPace(
        currentPercentage: Double,
        profileId: UUID
    ) -> Double {
        let snapshots = loadSnapshots(for: profileId)

        guard let firstSnapshot = snapshots.first else {
            // No snapshots at all — fall back to smoothed rate if available
            return UsageRateTracker.shared.smoothedWeeklyDailyRate(for: profileId) ?? 0
        }

        // Snapshot-based daily average
        let totalConsumed = max(0, currentPercentage - firstSnapshot.weeklyPercentageAtStart)
        let now = Date()
        let effectiveDays = max(0.01, now.timeIntervalSince(firstSnapshot.date) / 86400.0)
        let snapshotRate = totalConsumed / effectiveDays

        // Blend with smoothed rate: ramp from 100% smoothed → 0% over 3 days
        if let smoothedRate = UsageRateTracker.shared.smoothedWeeklyDailyRate(for: profileId) {
            let dailyWeight = min(1.0, effectiveDays / 3.0)
            return snapshotRate * dailyWeight + smoothedRate * (1.0 - dailyWeight)
        }

        return snapshotRate
    }

    /// How much usage has been consumed today so far
    func todayConsumption(
        currentPercentage: Double,
        profileId: UUID
    ) -> Double {
        let snapshots = loadSnapshots(for: profileId)
        let todayMidnight = Date().startOfDay()

        if let todaySnapshot = snapshots.last, todaySnapshot.date == todayMidnight {
            return max(0, currentPercentage - todaySnapshot.weeklyPercentageAtStart)
        }

        return 0
    }

    /// How much budget remains per day until reset
    func remainingBudgetPerDay(
        currentPercentage: Double,
        resetTime: Date?
    ) -> Double {
        let remaining = max(0, 100.0 - currentPercentage)
        let now = Date()
        guard let resetTime = resetTime, resetTime > now else {
            return remaining
        }

        let effectiveDaysRemaining = max(0.1, resetTime.timeIntervalSince(now) / 86400.0)
        return remaining / effectiveDaysRemaining
    }

    // MARK: - Cleanup

    /// Clear all daily snapshots for a profile
    func clearHistory(for profileId: UUID) {
        defaults.removeObject(forKey: storageKey(for: profileId))
    }

    // MARK: - Private Helpers

    private func storageKey(for profileId: UUID) -> String {
        "dailyConsumption_\(profileId.uuidString)"
    }

    private func loadSnapshots(for profileId: UUID) -> [DailySnapshot] {
        guard let data = defaults.data(forKey: storageKey(for: profileId)),
              let snapshots = try? decoder.decode([DailySnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    private func saveSnapshots(_ snapshots: [DailySnapshot], for profileId: UUID) {
        if let data = try? encoder.encode(snapshots) {
            defaults.set(data, forKey: storageKey(for: profileId))
        }
    }

    /// Generate short day labels for Mon-Sun
    private func generateDayLabels() -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current

        // Find a Monday to start from
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        components.weekday = 2 // Monday
        guard let monday = calendar.date(from: components) else {
            return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        }

        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: monday) ?? monday
            return day.shortDayLabel()
        }
    }

    /// Find the next available percentage after a given day index
    private func findNextSnapshotPercentage(
        after dayIndex: Int,
        snapshots: [Int: DailySnapshot],
        todayIndex: Int,
        currentPercentage: Double
    ) -> Double {
        // Look for the next day's snapshot
        for nextDay in (dayIndex + 1)...todayIndex {
            if nextDay == todayIndex {
                // Today's start = either today's snapshot or current percentage
                if let todaySnapshot = snapshots[todayIndex] {
                    return todaySnapshot.weeklyPercentageAtStart
                }
                return currentPercentage
            }
            if let snapshot = snapshots[nextDay] {
                return snapshot.weeklyPercentageAtStart
            }
        }
        return currentPercentage
    }
}
