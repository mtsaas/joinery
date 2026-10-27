import AppKit
import SwiftUI

/// Input SwiftUI has no gesture or key handler for, watched in the window over the canvas's frame:
/// - Two-finger scrolling or the mouse wheel pans; pinching or ⌘-scrolling zooms, around the pointer.
/// - Holding Space turns dragging anywhere into panning.
/// - Right-dragging pans; a right-click without dragging opens the command wheel there instead of a context menu.
///   Escape closes it.
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
        /// Where the pointer was at the last step of a right-button pan, or nil if the press hasn't become one.
        private var panLocation: CGPoint?

        override var isFlipped: Bool { true }

        /// Clicks go through to the canvas; this only watches events through its monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
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
                if modifiers == [.command, .shift] {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "k": return .toggleKey
                    case "u": return .toggleUnique
                    case "r": return .toggleRequired
                    default: break
                    }
                }
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
            case .keyDown where canvas.wheel != nil && event.keyCode == Key.escape:
                canvas.wheel = nil
            case .keyDown where canvas.designing != nil:
                // The table designer's keys, even while typing in it: what's typed applies as it closes.
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                switch (event.keyCode, modifiers, event.charactersIgnoringModifiers?.lowercased()) {
                case (Key.escape, [], _): withAnimation(.smooth(duration: 0.25)) { canvas.designing = nil }
                case (Key.tab, [], _) where canvas.isDesignerInGrid: canvas.designerCommand = .next
                case (Key.tab, .shift, _) where canvas.isDesignerInGrid: canvas.designerCommand = .previous
                case (Key.return, .command, _): canvas.designerCommand = .insert
                case (Key.delete, .command, _): canvas.designerCommand = .delete
                case (_, [.command, .shift], "k"): canvas.designerCommand = .primaryKey
                case (_, [.command, .shift], "r"): canvas.designerCommand = .required
                case (_, [.command, .shift], "u"): canvas.designerCommand = .unique
                default: return false
                }
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
                // Text being edited keeps its own menu, as do the feedback handles.
                #if DEBUG
                let isCorrecting = canvas.isFeedbackMode
                #else
                let isCorrecting = false
                #endif
                guard bounds.contains(convert(event.locationInWindow, from: nil)), !isTyping, !isCorrecting else {
                    rightClick = nil
                    return false
                }
                canvas.wheel = nil
                rightClick = event
            case .rightMouseDragged:
                guard let down = rightClick else { return false }
                let location = convert(event.locationInWindow, from: nil)
                if let previous = panLocation {
                    canvas.pan(by: location - previous)
                } else {
                    // A few points first, so a click with a little wobble is still a click.
                    let start = convert(down.locationInWindow, from: nil)
                    guard start.distance(to: location) > 3 else { return true }
                    NSCursor.closedHand.push()
                    canvas.pan(by: location - start)
                }
                panLocation = location
            case .rightMouseUp:
                guard let down = rightClick else { return false }
                rightClick = nil
                if panLocation != nil {
                    panLocation = nil
                    NSCursor.pop()
                } else if !canvas.isReadOnly {
                    canvas.wheelRequest = convert(down.locationInWindow, from: nil)
                }
            case .magnify, .scrollWheel:
                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location) else { return false }
                // Over the table designer, its own: its sample rows scroll sideways, its content up and down.
                if let frame = canvas.designerFrame, let height = window.contentView?.bounds.height,
                   frame.contains(CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)) {
                    return false
                }
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
