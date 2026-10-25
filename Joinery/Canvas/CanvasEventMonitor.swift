import AppKit
import SwiftUI

/// Input SwiftUI has no gesture or key handler for, watched in the window over the canvas's frame:
/// - Two-finger scrolling or the mouse wheel pans; pinching or ⌘-scrolling zooms, around the pointer.
/// - Holding Space turns dragging anywhere into panning.
/// - Right-dragging from empty canvas or a wire draws a line that zip-ties the wires it crosses. Right-clicks pass
///   through untouched, so tables and ties still get their context menus; a drag can't start while one is open.
/// - In the command palette, the arrow keys move through the matches and Escape closes it.
/// - While a table's cells are being edited, Tab and Shift-Tab step through them in our order (adding a column past
///   the last), Escape stops editing, ⌘⌫ deletes the column and ⇧⌘K toggles its primary key. The text field would
///   otherwise take these itself (and SwiftUI shortcuts don't reliably reach past it).
struct CanvasEventMonitor: NSViewRepresentable {
    let canvas: CanvasController

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.canvas = canvas
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.canvas = canvas
    }

    final class EventView: NSView {
        var canvas: CanvasController?
        private var monitor: Any?
        /// Where a right-button press started, while it might become a drag.
        private var rightClick: NSEvent?
        private var isMenuOpen = false
        private var menuObservers: [Any] = []

        override var isFlipped: Bool { true }

        /// Clicks go through to the canvas; this only watches events through its monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            menuObservers.forEach(NotificationCenter.default.removeObserver)
            menuObservers = []
            guard window != nil else { return }
            menuObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    let isOpen = name == NSMenu.didBeginTrackingNotification
                    MainActor.assumeIsolated {
                        self?.isMenuOpen = isOpen
                        self?.rightClick = nil
                    }
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown, .keyUp,
                                                                      .rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] event in
                let isHandled = MainActor.assumeIsolated { self?.handle(event) == true }
                return isHandled ? nil : event
            }
        }

        private enum Key {
            static let tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53, down: UInt16 = 125, up: UInt16 = 126
        }

        /// - Returns: Whether the event was used.
        private func handle(_ event: NSEvent) -> Bool {
            guard let canvas, let window, event.window === window else { return false }
            let isTyping = window.firstResponder is NSTextView
            switch event.type {
            case .keyDown where isTyping && canvas.showsPalette:
                switch event.keyCode {
                case Key.down: canvas.paletteHighlight += 1
                case Key.up: canvas.paletteHighlight = max(canvas.paletteHighlight - 1, 0)
                case Key.escape: canvas.showsPalette = false
                default: return false
                }
            case .keyDown where isTyping:
                guard canvas.editingTable != nil else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                switch event.keyCode {
                case Key.tab: canvas.fieldKey = modifiers.contains(.shift) ? .previous : .next
                case Key.escape: canvas.fieldKey = .done
                case Key.delete where modifiers == .command: canvas.fieldKey = .deleteColumn
                case _ where modifiers == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "k":
                    canvas.fieldKey = .togglePrimaryKey
                default: return false
                }
            case .keyDown, .keyUp:
                guard !isTyping, event.keyCode == Key.space,
                      event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return false }
                canvas.isSpaceHeld = event.type == .keyDown
            case .rightMouseDown:
                rightClick = bounds.contains(convert(event.locationInWindow, from: nil)) ? event : nil
                return false
            case .rightMouseDragged:
                guard let down = rightClick, !isMenuOpen else { return false }
                let start = convert(down.locationInWindow, from: nil), location = convert(event.locationInWindow, from: nil)
                if canvas.stroke == nil {
                    guard start.distance(to: location) > 3 else { return true }
                    NSCursor.crosshair.push()
                }
                canvas.stroke = .init(start: canvas.canvasPoint(start), end: canvas.canvasPoint(location))
            case .rightMouseUp:
                rightClick = nil
                guard canvas.stroke != nil else { return false }
                NSCursor.pop()
                canvas.isStrokeFinished = true
            case .magnify, .scrollWheel:
                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location) else { return false }
                if event.type == .magnify {
                    canvas.zoom(by: 1 + event.magnification, around: location)
                } else if event.modifierFlags.contains(.command) {
                    canvas.zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)), around: location)
                } else {
                    // A mouse wheel reports lines, not points.
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    canvas.pan(by: CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale))
                }
            default:
                return false
            }
            return true
        }
    }
}
