import Foundation

/// Runs `work` for 0..<count across the cores, or in order where a few aren't worth the handoff. WebAssembly has one
/// thread, so there it always runs in order.
func inParallel(_ count: Int, _ work: (Int) -> Void) {
    #if os(WASI)
    (0..<count).forEach(work)
    #else
    if count < 4 { (0..<count).forEach(work) } else { DispatchQueue.concurrentPerform(iterations: count, execute: work) }
    #endif
}
