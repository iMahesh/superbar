import AppKit
import SwiftUI

/// Two real windows with sample pages, opened by snapshot mode so the preview popover
/// shows real thumbnails. They belong to Superbar, so no other app's content is captured.
enum SnapshotWindows {
    static let releaseNotesTitle = "Superbar – Release notes"
    static let weatherTitle = "Weather in Fremont, CA"

    static func open() -> [NSWindow] {
        [make(releaseNotesTitle, ReleaseNotesPage(), x: 120),
         make(weatherTitle, WeatherPage(), x: 180)]
    }

    private static func make(_ title: String, _ page: some View, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: 200, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.orderFrontRegardless()
        return window
    }
}

private struct ReleaseNotesPage: View {
    private let items: [(String, String)] = [
        ("rectangle.split.2x1", "Snap windows to halves, quarters, and thirds"),
        ("eye.slash", "Auto-hide with a delay you choose"),
        ("display.2", "A bar on every display"),
        ("trash", "Trash next to the tray"),
        ("calendar", "A calendar with Today and a date field"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What’s new in Superbar").font(.system(size: 30, weight: .bold))
            Text("Version 0.1 · November 2026").font(.title3).foregroundStyle(.secondary)
            Divider()
            ForEach(items, id: \.1) { symbol, text in
                Label(text, systemImage: symbol).font(.title3)
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct WeatherPage: View {
    private let days: [(String, String, String)] = [
        ("Thu", "sun.max.fill", "71°"), ("Fri", "cloud.sun.fill", "68°"),
        ("Sat", "cloud.fill", "64°"), ("Sun", "cloud.rain.fill", "60°"), ("Mon", "sun.max.fill", "70°"),
    ]

    var body: some View {
        VStack(spacing: 18) { // grid: ok sample web page, not Superbar UI
            Text("Fremont, CA").font(.system(size: 30, weight: .semibold))
            HStack(spacing: 16) {
                Image(systemName: "sun.max.fill").symbolRenderingMode(.multicolor).font(.system(size: 64))
                Text("72°").font(.system(size: 76, weight: .thin))
            }
            Text("Sunny · H 74° L 52°").font(.title3)
            HStack(spacing: 28) {
                ForEach(days, id: \.0) { day, symbol, temp in
                    VStack(spacing: 8) {
                        Text(day).font(.headline)
                        Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.title)
                        Text(temp).font(.title3)
                    }
                }
            }
            .padding(18) // grid: ok sample web page, not Superbar UI
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14)) // grid: ok sample web page, not Superbar UI
        }
        .foregroundStyle(.white)
        .padding(30) // grid: ok sample web page, not Superbar UI
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 0.95), Color(red: 0.45, green: 0.75, blue: 1)],
                                   startPoint: .top, endPoint: .bottom))
    }
}
