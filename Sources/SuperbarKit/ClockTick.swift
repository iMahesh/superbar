import Foundation

public enum ClockTick {
    /// The start of the minute after `date`: the clock redraws then, not on a 1 s timer.
    public static func nextMinute(after date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        let start = calendar.date(from: parts) ?? date
        return calendar.date(byAdding: .minute, value: 1, to: start) ?? date.addingTimeInterval(60)
    }
}
