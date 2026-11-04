import AppKit
import Observation
import SwiftUI
import SuperbarKit

/// Every app in /Applications, /System/Applications, and ~/Applications, from
/// Spotlight, with a folder scan first so search works before Spotlight answers.
@Observable
final class AppIndex {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let name: String
        let bundleID: String?
        var id: String { bundleID ?? url.path }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var query: NSMetadataQuery?

    nonisolated static let folders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
    ]

    func start() {
        guard query == nil else { return }
        set(Self.scanFolders())
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        q.searchScopes = Self.folders.filter { !$0.path.hasSuffix("Utilities") }
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.readQuery() }
        }
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.readQuery() }
        }
        q.start()
        query = q
    }

    private func readQuery() {
        guard let q = query else { return }
        q.disableUpdates()
        let urls = (q.results as? [NSMetadataItem] ?? []).compactMap {
            ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map(URL.init(fileURLWithPath:))
        }
        q.enableUpdates()
        // Spotlight can be off or still indexing; never shrink the list because of it.
        if urls.count >= entries.count / 2 { set(urls + Self.scanFolders()) }
    }

    private func set(_ urls: [URL]) {
        var seen = Set<String>()
        var list: [Entry] = []
        for url in urls {
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let key = bundleID ?? url.path
            guard seen.insert(key).inserted else { continue }
            list.append(Entry(url: url, name: TaskbarModel.displayName(url), bundleID: bundleID))
        }
        entries = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func scanFolders() -> [URL] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }

    func entry(bundleID: String) -> Entry? {
        entries.first { $0.bundleID == bundleID } ?? IconCache.shared.url(forBundleID: bundleID).map {
            Entry(url: $0, name: TaskbarModel.displayName($0), bundleID: bundleID)
        }
    }

    func setForTesting(_ list: [Entry]) { entries = list }
}

@Observable
final class StartMenuModel {
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    private(set) var pins: [String]

    let index: AppIndex
    @ObservationIgnored let taskbar: TaskbarModel
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults

    static let defaultPins = [
        "com.apple.Safari", "com.apple.mail", "com.apple.iCal", "com.apple.Notes", "com.apple.Music",
        "com.apple.Photos", "com.apple.TextEdit", "com.apple.Terminal", "com.apple.systempreferences",
    ]

    init(index: AppIndex, taskbar: TaskbarModel, defaults: UserDefaults = Store.defaults) {
        self.index = index
        self.taskbar = taskbar
        self.defaults = defaults
        pins = defaults.stringArray(forKey: Store.Key.startPins) ?? Self.defaultPins
    }

    var pinnedEntries: [AppIndex.Entry] { Array(pins.compactMap(index.entry(bundleID:)).prefix(12)) }
    var recentEntries: [AppIndex.Entry] {
        Array(taskbar.recent.ids.filter { !pins.contains($0) }.compactMap(index.entry(bundleID:)).prefix(10))
    }

    var results: [AppIndex.Entry] {
        Array(SearchRanker.rank(index.entries, query: query) { $0.name }.prefix(12))
    }

    func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func openSelection() {
        let list = results
        guard list.indices.contains(selection) else { return }
        open(list[selection])
    }

    func open(_ entry: AppIndex.Entry) {
        onClose()
        taskbar.open(url: entry.url, bundleID: entry.bundleID)
    }

    func open(place url: URL) {
        onClose()
        NSWorkspace.shared.open(url)
    }

    func isPinned(_ entry: AppIndex.Entry) -> Bool { entry.bundleID.map(pins.contains) ?? false }

    func togglePin(_ entry: AppIndex.Entry) {
        guard let id = entry.bundleID else { return }
        if pins.contains(id) { pins.removeAll { $0 == id } } else { pins.append(id) }
        defaults.set(pins, forKey: Store.Key.startPins)
    }
}

/// Owns the Start panel: the one Superbar panel that becomes key, so it takes typing.
final class StartMenuController {
    let model: StartMenuModel
    private var panel: GlassPanel?
    private let settings: AppSettings
    static let size = NSSize(width: 460, height: 540)

    init(model: StartMenuModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        model.onClose = { [weak self] in self?.close() }
    }

    var isOpen: Bool { panel?.isVisible == true }

    func prewarm() {
        model.index.start()
        _ = makePanel()
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        model.index.start()
        model.query = ""
        let panel = makePanel()
        guard let screen = NSScreen.screens.first else { return }
        let origin = NSPoint(x: screen.frame.minX, y: screen.frame.minY + settings.metrics.height)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        // On the first open the field is made during layout, after this call returns,
        // and a cold launch can take a few frames. Try until it has focus, up to 0.5 s.
        focusField(panel)
        Task { [weak self] in
            for _ in 0..<10 {
                guard let self, self.isOpen, !self.searchHasFocus else { return }
                try? await Task.sleep(for: .milliseconds(50))
                self.focusField(panel)
            }
        }
        // A click in another app closes the menu. Clicks on the bar run their own action,
        // which closes it too (TaskbarModel.onCloseTransient).
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
                MainActor.assumeIsolated { [weak self] in self?.close() }
            }
        }
    }

    /// True when typing goes to the search field.
    var searchHasFocus: Bool { model.field?.currentEditor() != nil && panel?.isKeyWindow == true }

    private func focusField(_ panel: GlassPanel) {
        guard let field = model.field, field.currentEditor() == nil else { return }
        panel.makeFirstResponder(field)
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.query = ""
    }

    private var monitor: Any?

    private func makePanel() -> GlassPanel {
        if let panel { return panel }
        let panel = GlassPanel(content: StartMenuView(model: model), size: Self.size, cornerRadius: 8,
                               level: .popUpMenu, canKey: true)
        panel.onCancel = { [weak self] in self?.close() }
        panel.onResignKey = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }
}

// MARK: Views

struct StartMenuView: View {
    @Bindable var model: StartMenuModel

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: 280)
                .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                .padding(Space.sm)
            RightColumn(model: model)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity)
        }
        .background(Glass.tint)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.query.isEmpty {
                        ForEach(model.pinnedEntries) { AppRow(entry: $0, model: model, selected: false) }
                        let recent = model.recentEntries
                        if !recent.isEmpty {
                            Divider().padding(.vertical, Space.xs).padding(.horizontal, Space.sm)
                            Text("Recent").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, Space.md).padding(.bottom, Space.xs)
                            ForEach(recent) { AppRow(entry: $0, model: model, selected: false) }
                        }
                    } else {
                        let results = model.results
                        if results.isEmpty {
                            Text("No apps match “\(model.query)”").foregroundStyle(.secondary).padding(Space.md)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, entry in
                            AppRow(entry: entry, model: model, selected: i == model.selection)
                        }
                    }
                }
                .padding(.vertical, Space.sm)
            }
            .scrollIndicators(.automatic)
            Divider()
            SearchField(model: model)
                .frame(height: 24)
                .padding(Space.sm)
        }
    }
}

private struct AppRow: View {
    let entry: AppIndex.Entry
    let model: StartMenuModel
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(nsImage: IconCache.shared.icon(for: entry.id, url: entry.url, running: nil))
                .resizable().frame(width: 24, height: 24)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected || hovered ? Color.accentColor.opacity(selected ? 0.3 : 0.15) : .clear))
        .padding(.horizontal, Space.xs)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.open(entry) }
        .contextMenu {
            Button(model.isPinned(entry) ? "Unpin from Start Menu" : "Pin to Start Menu") { model.togglePin(entry) }
            if let id = entry.bundleID, !model.taskbar.pins.contains(id) {
                Button("Pin to Superbar") { model.taskbar.pin(id) }
            }
        }
        .accessibilityAddTraits(.isButton)
    }
}

private struct RightColumn: View {
    let model: StartMenuModel

    private struct Place: Identifiable {
        let name: String
        let symbol: String
        let url: URL
        var id: String { name }
    }

    private var places: [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Place(name: NSUserName(), symbol: "house", url: home),
            Place(name: "Documents", symbol: "doc", url: home.appending(path: "Documents")),
            Place(name: "Downloads", symbol: "arrow.down.circle", url: home.appending(path: "Downloads")),
            Place(name: "Pictures", symbol: "photo", url: home.appending(path: "Pictures")),
            Place(name: "Music", symbol: "music.note", url: home.appending(path: "Music")),
            Place(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            Place(name: "System Settings", symbol: "gearshape", url: URL(fileURLWithPath: "/System/Applications/System Settings.app")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(places) { place in
                PlaceRow(name: place.name, symbol: place.symbol) { model.open(place: place.url) }
                if place.name == NSUserName() || place.name == "Music" {
                    Divider().padding(.vertical, Space.xs)
                }
            }
            Spacer()
            PowerButton { action in
                model.onClose()
                Power.perform(action)
            }
        }
        .padding(.vertical, Space.lg)
        .padding(.trailing, Space.md)
        .padding(.leading, Space.xs)
    }
}

private struct PlaceRow: View {
    let name: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Label(name, systemImage: symbol)
            .lineLimit(1)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(hovered ? 0.16 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(hovered ? 0.3 : 0), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// "Shut Down", with an arrow for Sleep, Restart, Log Out, and Lock Screen.
private struct PowerButton: View {
    let perform: (PowerAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(PowerAction.shutDown.title) { perform(.shutDown) }
                .buttonStyle(.bordered)
            Menu {
                ForEach([PowerAction.sleep, .restart, .logOut, .lock]) { action in
                    Button(action.title) { perform(action) }
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More power options")
        }
        .controlSize(.regular)
    }
}

/// The search field at the bottom of the left column. AppKit, so the panel can
/// focus it on open and read ↑, ↓, Return, and Esc.
struct SearchField: NSViewRepresentable {
    @Bindable var model: StartMenuModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search apps"
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        model.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: StartMenuModel
        init(model: StartMenuModel) { self.model = model }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            model.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): model.moveSelection(-1); return true
            case #selector(NSResponder.moveDown(_:)): model.moveSelection(1); return true
            case #selector(NSResponder.insertNewline(_:)): model.openSelection(); return true
            case #selector(NSResponder.cancelOperation(_:)): model.onClose(); return true
            default: return false
            }
        }
    }
}
