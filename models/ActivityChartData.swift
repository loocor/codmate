import Foundation

struct ActivityChartDataPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let source: SessionSource.Kind
    let sessionCount: Int
    let duration: TimeInterval
    let totalTokens: Int
}

enum ActivityChartUnit: Equatable {
    case day
    case hour
}

struct ActivityChartData: Equatable {
    let points: [ActivityChartDataPoint]
    let unit: ActivityChartUnit
    
    static let empty = ActivityChartData(points: [], unit: .day)
}

extension Array where Element == SessionSummary {
    func generateChartData() -> ActivityChartData {
        guard !self.isEmpty else { return .empty }
        
        let dates = self.map { $0.startedAt }
        let minDate = dates.min() ?? Date()
        let maxDate = dates.max() ?? Date()
        
        // Heuristic: If all sessions are within the same calendar day, or span < 24h, use Hour.
        // Using Calendar to check "same day" is safer for "Today" view.
        let calendar = Calendar.current
        let isSameDay = calendar.isDate(minDate, inSameDayAs: maxDate)
        let range = maxDate.timeIntervalSince(minDate)
        
        // If explicit single day (same day) OR range < 24h, use Hour.
        let unit: ActivityChartUnit = (isSameDay || range < 86400) ? .hour : .day
        
        // Grouping
        var groups: [Date: [SessionSource.Kind: (count: Int, duration: TimeInterval, tokens: Int)]] = [:]
        
        for session in self {
            let date = session.startedAt
            let truncatedDate: Date
            if unit == .day {
                truncatedDate = calendar.startOfDay(for: date)
            } else {
                // Truncate to hour
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                truncatedDate = calendar.date(from: components) ?? date
            }
            
            let kind = session.source.baseKind
            var current = groups[truncatedDate, default: [:]][kind, default: (0, 0, 0)]
            current.count += 1
            current.duration += session.duration
            current.tokens += session.actualTotalTokens
            
            groups[truncatedDate, default: [:]][kind] = current
        }
        
        var points: [ActivityChartDataPoint] = []
        for (date, sourceMap) in groups {
            for (kind, stats) in sourceMap {
                points.append(ActivityChartDataPoint(
                    date: date,
                    source: kind,
                    sessionCount: stats.count,
                    duration: stats.duration,
                    totalTokens: stats.tokens
                ))
            }
        }
        
        return ActivityChartData(points: points.sorted { $0.date < $1.date }, unit: unit)
    }
}
