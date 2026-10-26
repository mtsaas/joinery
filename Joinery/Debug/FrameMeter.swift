#if DEBUG
import SwiftUI

/// Counts the wire layer's frames and times the work behind them, for the readout in the canvas's corner.
@MainActor @Observable
final class FrameMeter {
    static let shared = FrameMeter()

    /// What the readout shows. Refreshed a few times a second while frames are drawn and once after they stop, never
    /// on a timer: each refresh lays the window out again, which while idle would be all the app was doing.
    private(set) var summary = "idle"

    /// When each frame in the last second was drawn.
    @ObservationIgnored private var frames: [TimeInterval] = []
    /// Milliseconds the routing for the frame being drawn took, and the last routing and wire drawing.
    @ObservationIgnored private var routing = 0.0
    @ObservationIgnored private var lastRouting = 0.0
    @ObservationIgnored private var drawing = 0.0
    /// Every frame's total, for `report`.
    @ObservationIgnored private var totals: [Double] = []
    @ObservationIgnored private var isRefreshing = false

    var fps: Int {
        let now = ProcessInfo.processInfo.systemUptime
        return frames.count { now - $0 <= 1 }
    }

    func routed(in milliseconds: Double) {
        routing = milliseconds
        lastRouting = milliseconds
    }

    func drew(in milliseconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        frames.removeAll { now - $0 > 1 }
        frames.append(now)
        drawing = milliseconds
        totals.append(routing + drawing)
        routing = 0
        refreshSoon()
    }

    private func refreshSoon() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            try? await Task.sleep(for: .seconds(0.25))
            isRefreshing = false
            summary = String(format: "%3d fps   route %.1f ms   draw %.1f ms", fps, lastRouting, drawing)
            // Until the count has fallen to nothing.
            if fps > 0 { refreshSoon() }
        }
    }

    /// Frames and work since the last report, for scripted checks.
    func report(over seconds: Double) -> String {
        defer { totals = [] }
        let sorted = totals.sorted()
        guard !sorted.isEmpty else { return "no frames" }
        return String(format: "%.0f fps, work per frame %.2f ms median, %.2f ms worst", Double(sorted.count) / seconds,
                      sorted[sorted.count / 2], sorted[sorted.count - 1])
    }

    static func time<T>(_ body: () -> T) -> (T, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = body()
        return (result, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}

/// Frames per second while anything moves, and what each frame cost: routing the wires and drawing them.
struct FrameReadout: View {
    var body: some View {
        Text(FrameMeter.shared.summary)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: .capsule)
            .allowsHitTesting(false)
    }
}
#endif
