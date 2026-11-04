import AppKit
import SwiftUI

/// The month calendar that opens from the clock. Closes on the next click anywhere else.
final class CalendarController {
    private var panel: GlassPanel?
    private var monitor: Any?
    private let settings: AppSettings
    static let size = NSSize(width: 260, height: 268)

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let panel = self.panel ?? GlassPanel(content: CalendarView(), size: Self.size, cornerRadius: 8, level: .popUpMenu)
        self.panel = panel
        guard let screen = NSScreen.withPointer else { return }
        let origin = NSPoint(x: screen.frame.maxX - Self.size.width - Space.xs,
                             y: screen.frame.minY + settings.metrics.height + Space.xs)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { [weak self] in self?.close() }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
    }
}

struct CalendarView: View {
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: Space.sm) {
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            let columns = Array(repeating: GridItem(.fixed(28), spacing: Space.xs), count: 7)
            LazyVGrid(columns: columns, spacing: Space.xs) {
                ForEach(weekdaySymbols, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let today = calendar.isDateInToday(day)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.callout.monospacedDigit())
                            .frame(width: 28, height: 24)
                            .background(Circle().fill(today ? Color.accentColor : .clear).frame(width: 24, height: 24))
                    } else {
                        Color.clear.frame(width: 28, height: 24)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Glass.tint)
        .environment(\.colorScheme, .dark)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Blank slots before the 1st, then each day of the month.
    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: month)
        }
    }

    private func step(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }
}
