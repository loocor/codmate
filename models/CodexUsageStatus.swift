import Foundation

struct CodexUsageStatus: Equatable {
    let updatedAt: Date
    let contextUsedTokens: Int?
    let contextLimitTokens: Int?
    let primaryWindowUsedPercent: Double?
    let primaryWindowMinutes: Int?
    let primaryResetAt: Date?
    let secondaryWindowUsedPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetAt: Date?

    var contextUsedPercent: Double? {
        guard
            let used = contextUsedTokens,
            let limit = contextLimitTokens,
            limit > 0
        else { return nil }
        return Double(used) / Double(limit)
    }

    init(
        updatedAt: Date,
        contextUsedTokens: Int?,
        contextLimitTokens: Int?,
        primaryWindowUsedPercent: Double?,
        primaryWindowMinutes: Int?,
        primaryResetAt: Date?,
        secondaryWindowUsedPercent: Double?,
        secondaryWindowMinutes: Int?,
        secondaryResetAt: Date?
    ) {
        self.updatedAt = updatedAt
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.primaryWindowUsedPercent = primaryWindowUsedPercent
        self.primaryWindowMinutes = primaryWindowMinutes
        self.primaryResetAt = primaryResetAt
        self.secondaryWindowUsedPercent = secondaryWindowUsedPercent
        self.secondaryWindowMinutes = secondaryWindowMinutes
        self.secondaryResetAt = secondaryResetAt
    }
}

extension CodexUsageStatus {
    var contextUsageText: String? {
        guard let used = contextUsedTokens, let limit = contextLimitTokens else { return nil }
        return "\(TokenFormatter.string(from: used)) used / \(TokenFormatter.string(from: limit)) total"
    }

    var contextPercentText: String? {
        guard let percent = contextUsedPercent else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: percent))
            ?? String(format: "%.0f%%", percent * 100)
    }

    var primaryPercentText: String? {
        guard let percent = primaryWindowUsedPercent else { return nil }
        let remainingPercent = 100.0 - percent
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: remainingPercent / 100.0))
            ?? String(format: "%.0f%%", remainingPercent)
    }

    var secondaryPercentText: String? {
        guard let percent = secondaryWindowUsedPercent else { return nil }
        let remainingPercent = 100.0 - percent
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: remainingPercent / 100.0))
            ?? String(format: "%.0f%%", remainingPercent)
    }

    var primaryUsageText: String? {
        guard let percent = primaryWindowUsedPercent, let minutes = primaryWindowMinutes else { return nil }
        let usedMinutes = max(0, min(percent, 100)) / 100.0 * Double(minutes)
        let remainingMinutes = max(0, Double(minutes) - usedMinutes)
        return "\(UsageDurationFormatter.string(minutes: remainingMinutes)) remaining"
    }

    var secondaryUsageText: String? {
        guard let percent = secondaryWindowUsedPercent, let minutes = secondaryWindowMinutes else { return nil }
        let usedMinutes = max(0, min(percent, 100)) / 100.0 * Double(minutes)
        let remainingMinutes = max(0, Double(minutes) - usedMinutes)
        return "\(UsageDurationFormatter.string(minutes: remainingMinutes)) remaining"
    }

    var contextProgress: Double? { contextUsedPercent }

    var primaryProgress: Double? {
        guard let percent = primaryWindowUsedPercent else { return nil }
        let remainingPercent = 100.0 - percent
        return remainingPercent / 100.0
    }

    var secondaryProgress: Double? {
        guard let percent = secondaryWindowUsedPercent else { return nil }
        let remainingPercent = 100.0 - percent
        return remainingPercent / 100.0
    }

    func asProviderSnapshot(titleBadge: String? = nil) -> UsageProviderSnapshot {
        var metrics: [UsageMetricSnapshot] = []

        if contextUsedTokens != nil || contextLimitTokens != nil {
            metrics.append(
                UsageMetricSnapshot(
                    kind: .context,
                    label: "Context",
                    usageText: contextUsageText,
                    percentText: contextPercentText,
                    progress: contextProgress,
                    resetDate: nil,
                    fallbackWindowMinutes: nil
                )
            )
        }

        metrics.append(
            UsageMetricSnapshot(
                kind: .fiveHour,
                label: "5h limit",
                usageText: primaryUsageText,
                percentText: primaryPercentText,
                progress: primaryProgress,
                resetDate: validPrimaryResetAt,
                fallbackWindowMinutes: primaryWindowMinutes
            )
        )

        metrics.append(
            UsageMetricSnapshot(
                kind: .weekly,
                label: "Weekly limit",
                usageText: secondaryUsageText,
                percentText: secondaryPercentText,
                progress: secondaryProgress,
                resetDate: validSecondaryResetAt,
                fallbackWindowMinutes: secondaryWindowMinutes
            )
        )

        return UsageProviderSnapshot(
            provider: .codex,
            title: UsageProviderKind.codex.displayName,
            titleBadge: titleBadge,
            availability: .ready,
            metrics: metrics,
            updatedAt: updatedAt,
            statusMessage: nil,
            origin: .builtin
        )
    }

    init(snapshot: TokenUsageSnapshot) {
        self.init(
            updatedAt: snapshot.timestamp,
            contextUsedTokens: snapshot.totalTokens,
            contextLimitTokens: snapshot.contextWindow,
            primaryWindowUsedPercent: snapshot.primaryPercent,
            primaryWindowMinutes: snapshot.primaryWindowMinutes,
            primaryResetAt: snapshot.primaryResetAt,
            secondaryWindowUsedPercent: snapshot.secondaryPercent,
            secondaryWindowMinutes: snapshot.secondaryWindowMinutes,
            secondaryResetAt: snapshot.secondaryResetAt
        )
    }

    func overridingRateLimits(
        updatedAt: Date? = nil,
        primaryUsedPercent: Double?,
        primaryWindowMinutes: Int?,
        primaryResetAt: Date?,
        secondaryUsedPercent: Double?,
        secondaryWindowMinutes: Int?,
        secondaryResetAt: Date?
    ) -> CodexUsageStatus {
        CodexUsageStatus(
            updatedAt: updatedAt ?? self.updatedAt,
            contextUsedTokens: contextUsedTokens,
            contextLimitTokens: contextLimitTokens,
            primaryWindowUsedPercent: primaryUsedPercent ?? primaryWindowUsedPercent,
            primaryWindowMinutes: primaryWindowMinutes ?? self.primaryWindowMinutes,
            primaryResetAt: primaryResetAt ?? self.primaryResetAt,
            secondaryWindowUsedPercent: secondaryUsedPercent ?? secondaryWindowUsedPercent,
            secondaryWindowMinutes: secondaryWindowMinutes ?? self.secondaryWindowMinutes,
            secondaryResetAt: secondaryResetAt ?? self.secondaryResetAt
        )
    }

    private var validPrimaryResetAt: Date? {
        guard let reset = primaryResetAt else { return nil }
        return reset > updatedAt ? reset : nil
    }

    private var validSecondaryResetAt: Date? {
        guard let reset = secondaryResetAt else { return nil }
        return reset > updatedAt ? reset : nil
    }
}

enum UsageDurationFormatter {
    static func string(minutes: Double) -> String {
        if minutes >= 1440 {
            let days = minutes / 1440.0
            return days >= 10 ? String(format: "%.0fd", days) : String(format: "%.1fd", days)
        }
        if minutes >= 60 {
            let hours = minutes / 60.0
            return hours >= 10 ? String(format: "%.0fh", hours) : String(format: "%.1fh", hours)
        }
        return String(format: "%.0fm", minutes)
    }
}

extension NumberFormatter {
    static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let compactPercentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
