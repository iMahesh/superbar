import AppKit
import SwiftUI

/// The month calendar that opens from the clock. Closes on the next click anywhere else.
final class CalendarController {
    private var panel: GlassPanel?
    var panelForSnapshot: NSWindow? { panel }
    private var monitor: Any?
    private let settings: AppSettings
    static let size = NSSize(width: 264, height: 320)

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        // canKey: the date field takes typing. A non-activating panel becomes key without
        // taking the front app's place, as the Start menu does.
        let panel = self.panel ?? GlassPanel(content: CalendarView(), size: Self.size, cornerRadius: 8,
                                             level: .popUpMenu, canKey: true)
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        guard let screen = NSScreen.withPointer else { return }
        let origin = NSPoint(x: screen.frame.maxX - Self.size.width - Space.xs,
                             y: screen.frame.minY + settings.metrics.height + Space.xs)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        NotificationCenter.default.post(name: CalendarView.reset, object: nil)
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
    /// Sent on each open, so the calendar starts at today again.
    static let reset = Notification.Name("SuperbarCalendarReset")

    @State private var month = Self.monthStart(.now)
    /// The day picked by a click or the date field; today until then.
    @State private var selected = Calendar.current.startOfDay(for: .now)
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: Space.sm) {
            Text(selected.formatted(date: .complete, time: .omitted))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Space.sm) {
                // Type a date, or step the day, month, or year with the arrows.
                DatePicker("Go to date", selection: Binding(get: { selected }, set: go), displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                Spacer(minLength: 0)
                Button("Today") { go(.now) }
                    .disabled(calendar.isDateInToday(selected) && month == Self.monthStart(.now))
            }
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
                // By position: the letters repeat (T, S), so they can't be their own IDs.
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let today = calendar.isDateInToday(day)
                        let picked = calendar.isDate(day, inSameDayAs: selected)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.callout.monospacedDigit())
                            .frame(width: 28, height: 24)
                            .background(Circle().fill(today ? Color.accentColor : .clear).frame(width: 24, height: 24))
                            .overlay(Circle().strokeBorder(picked && !today ? Color.accentColor : .clear, lineWidth: 1.5)  // grid: ok ring stroke width, not layout
                                .frame(width: 24, height: 24))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = day }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(picked ? .isSelected : [])
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
        .onReceive(NotificationCenter.default.publisher(for: Self.reset)) { _ in go(.now) }
    }

    /// Selects a day and shows its month.
    private func go(_ date: Date) {
        selected = calendar.startOfDay(for: date)
        month = Self.monthStart(date)
    }

    private static func monthStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
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
