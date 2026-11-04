import AppKit
import Observation
import SwiftUI

/// Hover previews above a button: 400 ms to show, 300 ms to hide after the
/// pointer leaves both the button and the popover, and an instant switch
/// when the pointer moves to the next button.
@Observable
final class PreviewController {
    private(set) var appID: String?
    @ObservationIgnored private let model: TaskbarModel
    @ObservationIgnored private var panel: GlassPanel?
    @ObservationIgnored private var anchor: NSRect = .zero
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var overPopover = false

    static let thumbWidth: CGFloat = 200
    static let thumbHeight: CGFloat = 124

    init(model: TaskbarModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func prewarm() {
        _ = makePanel()
    }

    func buttonHover(_ id: String, inside: Bool, rect: NSRect) {
        if inside {
            hideTask?.cancel()
            showTask?.cancel()
            if model.drag != nil { return }
            if isVisible {
                show(id, anchor: rect)
                return
            }
            showTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                show(id, anchor: rect)
            }
        } else {
            showTask?.cancel()
            scheduleHide()
        }
    }

    func popoverHover(_ inside: Bool) {
        overPopover = inside
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !overPopover, model.hoveredID != appID else { return }
            hide()
        }
    }

    /// A click on a grouped app: no hover delay.
    func showNow(_ id: String, anchor: NSRect) {
        showTask?.cancel()
        hideTask?.cancel()
        show(id, anchor: anchor)
    }

    func show(_ id: String, anchor: NSRect) {
        guard let app = model.app(id) else { hide(); return }
        appID = id
        self.anchor = anchor
        let panel = makePanel()
        layout(panel, count: app.windows.count)
        panel.orderFrontRegardless()
        WindowIndex.shared.refreshAll()
        let ids = app.visibleWindows.map(\.windowID)
        Task { await WindowThumbnails.shared.capture(ids) }
    }

    func hide() {
        showTask?.cancel()
        hideTask?.cancel()
        overPopover = false
        panel?.orderOut(nil)
        appID = nil
    }

    /// Called by the view when the window count changes (a window closed).
    func relayout(count: Int) {
        guard let panel, isVisible else { return }
        if count == 0 && model.app(appID ?? "")?.isRunning != true { hide(); return }
        layout(panel, count: count)
    }

    private func layout(_ panel: GlassPanel, count: Int) {
        let size = Self.size(for: count)
        guard let screen = NSScreen.of(anchor) else { return }
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.frame.minX + Space.xs), screen.frame.maxX - size.width - Space.xs)
        let y = anchor.maxY + Space.xs
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    static func size(for count: Int) -> NSSize {
        if count == 0 { return NSSize(width: 180, height: 40) }
        let n = CGFloat(min(count, 6))
        return NSSize(width: n * thumbWidth + (n - 1) * Space.sm + Space.md * 2,
                      height: thumbHeight + 28 + Space.md * 2)
    }

    private func makePanel() -> GlassPanel {
        if let panel { return panel }
        let view = PreviewView(model: model, controller: self, thumbnails: WindowThumbnails.shared)
        let panel = GlassPanel(content: view, size: Self.size(for: 1), cornerRadius: 8, level: .popUpMenu)
        self.panel = panel
        return panel
    }
}

struct PreviewView: View {
    let model: TaskbarModel
    let controller: PreviewController
    let thumbnails: WindowThumbnails

    var body: some View {
        let app = controller.appID.flatMap { model.app($0) }
        let windows = Array((app?.windows ?? []).prefix(6))
        ZStack {
            Glass.tint
            if let app {
                if windows.isEmpty {
                    Text(app.name).font(.callout).lineLimit(1).padding(.horizontal, Space.md)
                } else {
                    HStack(alignment: .top, spacing: Space.sm) {
                        ForEach(windows) { window in
                            ThumbnailCard(app: app, window: window, image: thumbnails.images[window.windowID]) {
                                controller.hide()
                                model.focus(window, of: app.id)
                            } close: {
                                model.close(window, of: app.id)
                            }
                        }
                    }
                    .padding(Space.md)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onHover { controller.popoverHover($0) }
        .onChange(of: windows.count) { _, count in controller.relayout(count: count) }
    }
}

private struct ThumbnailCard: View {
    let app: TaskbarApp
    let window: AppWindow
    let image: NSImage?
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                Text(window.title.isEmpty ? app.name : window.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .help("Close window")
            }
            .frame(height: 16)
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    // No Screen Recording, or never captured: the big icon.
                    Image(nsImage: app.icon).resizable().frame(width: 64, height: 64)
                }
                if window.isMinimized {
                    Text("Minimized")
                        .font(.caption2)
                        .padding(.horizontal, Space.xs)
                        .background(.black.opacity(0.5), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: PreviewController.thumbWidth - Space.sm, height: PreviewController.thumbHeight - Space.sm)
        }
        .padding(Space.xs)
        .frame(width: PreviewController.thumbWidth)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovered ? 0.16 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(hovered ? 0.35 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: select)
    }
}
