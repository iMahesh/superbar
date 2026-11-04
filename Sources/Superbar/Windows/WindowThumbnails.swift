import AppKit
import Observation
import ScreenCaptureKit

/// Window pictures for the preview popover, with ScreenCaptureKit. Memory only.
/// Minimized windows cannot be captured, so the last picture stays in the cache.
@Observable
final class WindowThumbnails {
    static let shared = WindowThumbnails()

    private(set) var images: [CGWindowID: NSImage] = [:]
    @ObservationIgnored private var generation = 0

    /// Captures each window that is on screen. Max 440 by 280 px, no cursor, no shadow.
    func capture(_ ids: [CGWindowID]) async {
        let ids = ids.filter { $0 != 0 }
        guard !ids.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        generation += 1
        let mine = generation
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let windows = content.windows.filter { ids.contains($0.windowID) }
        // SCWindow and SCContentFilter are not Sendable: one main-actor task per window.
        let tasks = windows.map { window in
            Task { @MainActor in
                let size = Self.fit(window.frame.size, in: CGSize(width: 440, height: 280))
                let config = SCStreamConfiguration()
                config.width = Int(size.width)
                config.height = Int(size.height)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
                if mine == self.generation || self.images[window.windowID] == nil {
                    self.images[window.windowID] = NSImage(cgImage: image, size: CGSize(width: size.width / 2, height: size.height / 2))
                }
            }
        }
        for task in tasks { await task.value }
    }

    /// Keeps the cache to windows that still exist.
    func prune(keeping ids: Set<CGWindowID>) {
        let stale = images.keys.filter { !ids.contains($0) }
        for id in stale { images[id] = nil }
    }

    func setForTesting(_ image: NSImage, for id: CGWindowID) {
        images[id] = image
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height, 2)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
