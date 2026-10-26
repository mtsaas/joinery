import AppKit
import SwiftUI

/// Input SwiftUI has no gesture or key handler for, watched in the window over the canvas's frame:
/// - Two-finger scrolling or the mouse wheel pans; pinching or ⌘-scrolling zooms, around the pointer.
/// - Holding Space turns dragging anywhere into panning.
/// - Right-dragging from empty canvas or a wire draws a line that zip-ties the wires it crosses. Right-clicks pass
///   through untouched, so tables and ties still get their context menus; a drag can't start while one is open.
/// - In the command palette, the arrow keys move through the matches and Escape closes it.
/// - On a table's grid, the spreadsheet keys: arrows, Tab and Return move the cursor; typing, F2, Delete and Space
///   edit; Escape cancels, then leaves. While a cell is being edited these are caught before its text field, which
///   would otherwise take them itself (and SwiftUI shortcuts don't reliably reach past it).
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
            static let `return`: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
            static let enter: UInt16 = 76, forwardDelete: UInt16 = 117, f2: UInt16 = 120
            static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        }

        /// What a key does on the grid, or nil to let it through.
        private func cellCommand(for event: NSEvent, isEditing: Bool) -> CanvasController.CellCommand? {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let shift = modifiers == .shift
            switch event.keyCode {
            case Key.tab:
                return isEditing ? .commit(then: shift ? .previous : .next) : .move(shift ? .previous : .next)
            case Key.return, Key.enter:
                if modifiers == .command { return .insertColumn }
                let move: CanvasController.CellMove = shift ? .up : .downOrNew
                return isEditing ? .commit(then: move) : .move(move)
            case Key.escape:
                return isEditing ? .cancel : .leave
            case Key.up, Key.down:
                let move: CanvasController.CellMove = event.keyCode == Key.up ? .up : .down
                return isEditing ? .commit(then: move) : .move(move)
            case Key.left, Key.right:
                return isEditing ? nil : .move(event.keyCode == Key.left ? .left : .right)
            case Key.delete where modifiers == .command:
                return .deleteColumn
            case Key.delete, Key.forwardDelete:
                return isEditing ? nil : .clear
            case Key.f2:
                return isEditing ? nil : .edit(replacingWith: nil)
            case Key.space where !isEditing && modifiers.isEmpty:
                return .space
            default:
                if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "k" { return .toggleKey }
                // Typing on a cell starts editing it, with what's typed in place of what was there.
                guard !isEditing, modifiers.isSubset(of: .shift), let text = event.characters, Self.isPrintable(text) else { return nil }
                return .edit(replacingWith: text)
            }
        }

        /// Text a key types, as opposed to a control or function key.
        private static func isPrintable(_ text: String) -> Bool {
            !text.isEmpty && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }
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
            case .keyDown where canvas.cell != nil && (!isTyping || canvas.isEditingCell):
                // Typed in the moment before the cell's editor takes focus: keep it for the editor.
                if canvas.isEditingCell, !isTyping, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                   let text = event.characters, Self.isPrintable(text) {
                    canvas.draft += text
                    return true
                }
                guard let command = cellCommand(for: event, isEditing: canvas.isEditingCell) else { return false }
                canvas.cellCommand = command
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
