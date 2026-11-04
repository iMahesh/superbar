import AppKit
import SwiftUI

/// The bar: Start orb, app buttons, tray, clock, and the show-desktop strip.
struct TaskbarView: View {
    let model: TaskbarModel
    let tray: TrayModel
    let settings: AppSettings
    /// Snapshots draw without the AppKit mouse views, which ImageRenderer cannot draw.
    var interactive = true

    var body: some View {
        let m = settings.metrics
        ZStack(alignment: .top) {
            Glass.tint
            if interactive {
                MouseCatcher(handlers: .init(menu: { model.barMenu() }))
            }
            HStack(spacing: 0) {
                StartOrb(size: m.orb) { model.onToggleStart() }
                    .padding(.horizontal, Space.xs)
                MissionControlButton(metrics: m) { model.openMissionControl() }
                AppStrip(model: model, metrics: m, interactive: interactive)
                Spacer(minLength: Space.sm)
                TrayView(model: model, tray: tray, metrics: m, interactive: interactive)
                ClockView(tray: tray, metrics: m) { model.onToggleCalendar() }
                ShowDesktopStrip(width: m.showDesktopWidth, isOn: model.showDesktopOn) { model.toggleShowDesktop() }
            }
            Glass.highlight.frame(height: 1)
        }
        .frame(height: m.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: App buttons

private struct AppStrip: View {
    let model: TaskbarModel
    let metrics: BarMetrics
    let interactive: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.apps) { app in
                let dragging = model.drag?.id == app.id
                AppButton(app: app, metrics: metrics, isHovered: model.hoveredID == app.id || dragging)
                    .overlay {
                        if interactive { MouseCatcher(handlers: handlers(for: app)) }
                    }
                    .offset(x: dragging ? model.drag?.offset ?? 0 : 0)  // grid: ok follows the pointer while dragging
                    .zIndex(dragging ? 1 : 0)
                    .help(app.name)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.apps.map(\.id))
    }

    private func handlers(for app: TaskbarApp) -> MouseCatcher.Handlers {
        let id = app.id
        let stride = metrics.buttonWidth
        return MouseCatcher.Handlers(
            click: { front, shift, rect in model.click(id, frontAtMouseDown: front, shift: shift, rect: rect) },
            middleClick: { model.newWindow(id) },
            menu: {
                model.onCloseTransient()
                return model.menu(for: id)
            },
            hover: { inside, rect in
                if inside { model.hoveredID = id } else if model.hoveredID == id { model.hoveredID = nil }
                model.onButtonHover(id, inside, rect)
            },
            drag: { offset in
                model.onCloseTransient()
                model.drag = DragState(id: id, offset: offset)
            },
            dragEnd: { offset in model.endDrag(id, offset: offset, stride: stride) }
        )
    }
}

struct AppButton: View {
    let app: TaskbarApp
    let metrics: BarMetrics
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack {
            if app.isRunning {
                // Grouped: a second frame edge behind, like stacked buttons.
                if app.windows.count > 1 {
                    shape.strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        .padding(.vertical, Space.xs)
                        .offset(x: Space.xs)  // grid: ok the stacked edge of a grouped button
                        .padding(.trailing, 4)
                }
                shape.fill(LinearGradient(colors: [.white.opacity(app.isActive ? 0.30 : 0.14),
                                                   .white.opacity(app.isActive ? 0.12 : 0.04)],
                                          startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(.white.opacity(app.isActive ? 0.45 : 0.22), lineWidth: 1))
                    .overlay(alignment: .top) {
                        // Inner top highlight: the raised look.
                        Capsule().fill(.white.opacity(app.isActive ? 0.5 : 0.25))
                            .frame(height: 1).padding(.horizontal, 4).padding(.top, 1)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
            }
            if isHovered {
                shape.fill(RadialGradient(colors: [app.glowColor.opacity(0.85), app.glowColor.opacity(0)],
                                          center: .bottom, startRadius: 0, endRadius: metrics.buttonWidth * 0.75))
                    .overlay(shape.strokeBorder(app.glowColor.opacity(0.7), lineWidth: 1))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                    .blendMode(.plusLighter)
            }
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: metrics.icon, height: metrics.icon)
                .opacity(app.isHidden ? 0.6 : 1)
        }
        .frame(width: metrics.buttonWidth, height: metrics.height)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Start orb

/// An original orb: blue glass with a gloss and a white four-point spark.
struct StartOrb: View {
    let size: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        OrbArt(size: size)
            .brightness(hovered ? 0.12 : 0)
            .shadow(color: Color(red: 0.3, green: 0.75, blue: 1).opacity(hovered ? 0.9 : 0), radius: 6)
            .contentShape(Circle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .accessibilityElement()
            .accessibilityLabel("Start")
            .accessibilityAddTraits(.isButton)
    }
}

/// The orb's drawing, shared by the Start button and the app icon.
struct OrbArt: View {
    let size: CGFloat

    var body: some View {
        let line = max(1, size / 40)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.85, blue: 1.0),
                                              Color(red: 0.12, green: 0.45, blue: 0.88),
                                              Color(red: 0.03, green: 0.18, blue: 0.48)],
                                     center: UnitPoint(x: 0.5, y: 0.85), startRadius: 0, endRadius: size * 0.62))
            Circle().strokeBorder(Color(red: 0.02, green: 0.10, blue: 0.28), lineWidth: line)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: line).padding(line)
            // Gloss on the upper half.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.74, height: size * 0.46)
                .offset(y: -size * 0.2)  // grid: ok gloss scales with the orb
            Spark()
                .fill(.white)
                .shadow(color: Color(red: 0.4, green: 0.8, blue: 1).opacity(0.9), radius: size * 0.075)
                .frame(width: size * 0.42, height: size * 0.42)
        }
        .frame(width: size, height: size)
    }
}

/// Opens Mission Control, like the Dock's Mission Control app.
struct MissionControlButton: View {
    let metrics: BarMetrics
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Image(systemName: "rectangle.3.group")
            .font(.system(size: metrics.clockFont + 4))
            .foregroundStyle(.primary)
            .frame(width: metrics.missionControlWidth - Space.xs, height: metrics.height - Space.sm)
            .background(shape.fill(.white.opacity(hovered ? 0.16 : 0)))
            .overlay(shape.strokeBorder(.white.opacity(hovered ? 0.3 : 0), lineWidth: 1))
            .frame(width: metrics.missionControlWidth, height: metrics.height)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .help("Mission Control")
            .accessibilityElement()
            .accessibilityLabel("Mission Control")
            .accessibilityAddTraits(.isButton)
    }
}

/// Four curved points, an original glyph for the orb.
struct Spark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let pinch = r * 0.18
        var p = Path()
        let tips = [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y),
                    CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)]
        p.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4]
            let corner = CGPoint(x: c.x + (i == 0 || i == 1 ? pinch : -pinch), y: c.y + (i == 1 || i == 2 ? pinch : -pinch))
            p.addQuadCurve(to: next, control: corner)
        }
        p.closeSubpath()
        return p
    }
}

// MARK: Tray and clock

private struct TrayView: View {
    let model: TaskbarModel
    let tray: TrayModel
    let metrics: BarMetrics
    let interactive: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            TrayButton(symbol: tray.networkSymbol, help: tray.networkHelp, width: 28, metrics: metrics,
                       interactive: interactive) { model.onTrayClick(.network, $0) }
            TrayButton(symbol: tray.volumeSymbol, help: tray.volumeHelp, width: 28, metrics: metrics,
                       interactive: interactive) { model.onTrayClick(.sound, $0) }
            if let symbol = tray.batterySymbol, let battery = tray.battery {
                TrayButton(symbol: symbol, help: "Battery \(battery.percent)%\(battery.charging ? ", charging" : "")",
                           width: 32, metrics: metrics, interactive: interactive) { model.onTrayClick(.battery, $0) }
            }
        }
        .padding(.horizontal, Space.xs)
    }
}

/// A tray icon that opens its popover. The AppKit mouse view gives the icon's screen rect.
private struct TrayButton: View {
    let symbol: String
    let help: String
    let width: CGFloat
    let metrics: BarMetrics
    let interactive: Bool
    let action: (NSRect) -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: metrics.clockFont + 1))
            .foregroundStyle(.primary)
            .frame(width: width, height: metrics.height - Space.sm)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(hovered ? 0.14 : 0)))
            .overlay {
                if interactive {
                    MouseCatcher(handlers: .init(
                        click: { _, _, rect in action(rect) },
                        hover: { inside, _ in hovered = inside }))
                }
            }
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

private struct ClockView: View {
    let tray: TrayModel
    let metrics: BarMetrics
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Text(tray.timeText)
            Text(tray.dateText)
        }
        .font(.system(size: metrics.clockFont).monospacedDigit())
        .foregroundStyle(.primary)
        .padding(.horizontal, Space.sm)
        .frame(maxHeight: .infinity)
        .background(.white.opacity(hovered ? 0.12 : 0))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ShowDesktopStrip: View {
    let width: CGFloat
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Rectangle()
            .fill(.white.opacity(hovered || isOn ? 0.22 : 0.06))
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.3)).frame(width: 1) }
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .help("Show desktop")
            .accessibilityElement()
            .accessibilityLabel("Show desktop")
            .accessibilityAddTraits(.isButton)
    }
}
