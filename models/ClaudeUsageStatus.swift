import Foundation

struct ClaudeUsageStatus: Equatable {
    let updatedAt: Date
    let modelName: String?
    let contextUsedTokens: Int?
    let contextLimitTokens: Int?
    let fiveHourUsedMinutes: Double?
    let fiveHourWindowMinutes: Double
    let fiveHourResetAt: Date?
    let weeklyUsedMinutes: Double?
    let weeklyWindowMinutes: Double
    let weeklyResetAt: Date?
    let sessionExpiresAt: Date?

    init(
        updatedAt: Date,
        modelName: String?,
        contextUsedTokens: Int?,
        contextLimitTokens: Int?,
        fiveHourUsedMinutes: Double?,
        fiveHourWindowMinutes: Double = 300,
        fiveHourResetAt: Date?,
        weeklyUsedMinutes: Double?,
        weeklyWindowMinutes: Double = 10_080,
        weeklyResetAt: Date?,
        sessionExpiresAt: Date? = nil
    ) {
        self.updatedAt = updatedAt
        self.modelName = modelName
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.fiveHourUsedMinutes = fiveHourUsedMinutes
        self.fiveHourWindowMinutes = fiveHourWindowMinutes
        self.fiveHourResetAt = fiveHourResetAt
        self.weeklyUsedMinutes = weeklyUsedMinutes
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.weeklyResetAt = weeklyResetAt
        self.sessionExpiresAt = sessionExpiresAt
    }

    private var contextProgress: Double? {
        guard
            let used = contextUsedTokens,
            let limit = contextLimitTokens,
            limit > 0
        else { return nil }
        return Double(used) / Double(limit)
    }

    private var fiveHourProgress: Double? {
        guard let used = fiveHourUsedMinutes, fiveHourWindowMinutes > 0 else { return nil }
        return used / fiveHourWindowMinutes
    }

    private var weeklyProgress: Double? {
        guard let used = weeklyUsedMinutes, weeklyWindowMinutes > 0 else { return nil }
        return used / weeklyWindowMinutes
    }

    private var sessionProgress: Double? {
        guard let expiresAt = sessionExpiresAt else { return nil }
        let sessionDuration: TimeInterval = 8 * 3600 // 8 hours in seconds
        let remaining = expiresAt.timeIntervalSince(updatedAt)
        let elapsed = sessionDuration - remaining
        let progress = elapsed / sessionDuration
        return progress
    }

    func asProviderSnapshot() -> UsageProviderSnapshot {
        var metrics: [UsageMetricSnapshot] = []

        metrics.append(
            UsageMetricSnapshot(
                kind: .context,
                label: "Context",
                usageText: contextUsageText,
                percentText: contextPercentText,
                progress: contextProgress?.clamped01(),
                resetDate: nil,
                fallbackWindowMinutes: nil
            )
        )

        metrics.append(
            UsageMetricSnapshot(
                kind: .fiveHour,
                label: "5h limit",
                usageText: fiveHourUsageText,
                percentText: fiveHourPercentText,
                progress: fiveHourProgress?.clamped01(),
                resetDate: fiveHourResetAt,
                fallbackWindowMinutes: Int(fiveHourWindowMinutes)
            )
        )

        metrics.append(
            UsageMetricSnapshot(
                kind: .weekly,
                label: "Weekly limit",
                usageText: weeklyUsageText,
                percentText: weeklyPercentText,
                progress: weeklyProgress?.clamped01(),
                resetDate: weeklyResetAt,
                fallbackWindowMinutes: Int(weeklyWindowMinutes)
            )
        )

        metrics.append(
            UsageMetricSnapshot(
                kind: .sessionExpiry,
                label: "Session (8h)",
                usageText: sessionUsageText,
                percentText: sessionPercentText,
                progress: sessionProgress?.clamped01(),
                resetDate: sessionExpiresAt,
                fallbackWindowMinutes: 480 // 8 hours in minutes
            )
        )

        return UsageProviderSnapshot(
            provider: .claude,
            title: UsageProviderKind.claude.displayName,
            availability: .ready,
            metrics: metrics,
            updatedAt: updatedAt,
            statusMessage: nil,
            origin: .builtin
        )
    }

    private var contextUsageText: String? {
        guard let used = contextUsedTokens else { return nil }
        if let limit = contextLimitTokens {
            return "\(TokenFormatter.string(from: used)) used / \(TokenFormatter.string(from: limit)) total"
        }
        return "\(TokenFormatter.string(from: used)) used"
    }

    private var contextPercentText: String? {
        guard let ratio = contextProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: ratio))
            ?? String(format: "%.0f%%", ratio * 100)
    }

    private var fiveHourUsageText: String? {
        if let resetAt = fiveHourResetAt {
            let remaining = resetAt.timeIntervalSince(updatedAt)
            if remaining <= 0 {
                return "Reset"
            }
            let minutes = Int(remaining / 60)
            let hours = minutes / 60
            let mins = minutes % 60
            if hours > 0 {
                return "\(hours)h \(mins)m remaining"
            } else {
                return "\(mins)m remaining"
            }
        }
        // Fallback if no reset date
        guard let usedMinutes = fiveHourUsedMinutes else { return nil }
        let remainingMinutes = max(0, fiveHourWindowMinutes - usedMinutes)
        return "\(UsageDurationFormatter.string(minutes: remainingMinutes)) remaining"
    }

    private var fiveHourPercentText: String? {
        guard let progress = fiveHourProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: progress))
            ?? String(format: "%.0f%%", progress * 100)
    }

    private var weeklyUsageText: String? {
        if let resetAt = weeklyResetAt {
            let remaining = resetAt.timeIntervalSince(updatedAt)
            if remaining <= 0 {
                return "Reset"
            }
            let minutes = Int(remaining / 60)
            let hours = minutes / 60
            let days = hours / 24
            let remainingHours = hours % 24
            let remainingMins = minutes % 60

            if days > 0 {
                if remainingHours > 0 {
                    return "\(days)d \(remainingHours)h remaining"
                } else {
                    return "\(days)d remaining"
                }
            } else if hours > 0 {
                return "\(hours)h \(remainingMins)m remaining"
            } else {
                return "\(remainingMins)m remaining"
            }
        }
        // Fallback if no reset date
        guard let usedMinutes = weeklyUsedMinutes else { return nil }
        let remainingMinutes = max(0, weeklyWindowMinutes - usedMinutes)
        return "\(UsageDurationFormatter.string(minutes: remainingMinutes)) remaining"
    }

    private var weeklyPercentText: String? {
        guard let progress = weeklyProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: progress))
            ?? String(format: "%.0f%%", progress * 100)
    }

    private var sessionUsageText: String? {
        guard let expiresAt = sessionExpiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSince(updatedAt)
        if remaining <= 0 {
            return "Expired"
        }
        let hours = Int(remaining / 3600)
        let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 {
            return "\(hours)h \(minutes)m remaining"
        } else {
            return "\(minutes)m remaining"
        }
    }

    private var sessionPercentText: String? {
        guard let progress = sessionProgress else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: progress))
            ?? String(format: "%.0f%%", progress * 100)
    }
}

private extension Double {
    func clamped01() -> Double {
        if self.isNaN { return 0 }
        return max(0, min(self, 1))
    }
}
