#if DEBUG
import SwiftUI

/// Counts the wire layer's frames and times the work behind them, for the readout in the canvas's corner.
@MainActor
final class FrameMeter {
    static let shared = FrameMeter()

    /// When each frame in the last second was drawn.
    private var frames: [TimeInterval] = []
    /// Milliseconds the last routing and the last wire drawing took.
    private(set) var routing = 0.0, drawing = 0.0
    /// Every frame's total, for `report`.
    private var totals: [Double] = []

    var fps: Int {
        let now = ProcessInfo.processInfo.systemUptime
        return frames.count { now - $0 <= 1 }
    }

    func routed(in milliseconds: Double) { routing = milliseconds }

    func drew(in milliseconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        frames.removeAll { now - $0 > 1 }
        frames.append(now)
        drawing = milliseconds
        totals.append(routing + drawing)
        routing = 0
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
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let meter = FrameMeter.shared
            Text(String(format: "%3d fps   route %.1f ms   draw %.1f ms", meter.fps, meter.routing, meter.drawing))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: .capsule)
                .allowsHitTesting(false)
        }
    }
}
#endif
