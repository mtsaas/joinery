import AppKit
import SwiftUI

/// What a right-click offers, as a native menu: commands in sections, split by lines, some in submenus.
indirect enum MenuEntry {
    case command(PaletteCommand)
    case submenu(String, symbol: String, [[MenuEntry]])

    /// Every command in `sections`, submenus' too.
    static func commands(in sections: [[MenuEntry]]) -> [PaletteCommand] {
        sections.joined().flatMap { entry in
            switch entry {
            case .command(let command): [command]
            case .submenu(_, _, let inner): commands(in: inner)
            }
        }
    }

    /// `sections` with only the commands `keep` allows, leaving out submenus and sections emptied.
    static func filter(_ sections: [[MenuEntry]], _ keep: (PaletteCommand) -> Bool) -> [[MenuEntry]] {
        sections.map { section in
            section.compactMap { entry in
                switch entry {
                case .command(let command): keep(command) ? entry : nil
                case .submenu(let title, let symbol, let inner):
                    filter(inner, keep).nonEmpty.map { .submenu(title, symbol: symbol, $0) }
                }
            }
        }
        .filter { !$0.isEmpty }
    }

    static func menu(_ sections: [[MenuEntry]]) -> NSMenu {
        let menu = NSMenu()
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in section {
                switch entry {
                case .command(let command): menu.addItem(CommandItem(command))
                case .submenu(let title, let symbol, let inner):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    item.submenu = self.menu(inner)
                    item.showsImage()
                    menu.addItem(item)
                }
            }
        }
        return menu
    }

    /// One of the colors to choose, as a command: a swatch, checked if it's `current`.
    static func color(_ color: TableColor, current: TableColor?, set: @escaping (TableColor) -> Void) -> MenuEntry {
        .command(PaletteCommand(id: "color:\(color.rawValue)", title: color.rawValue.capitalized, symbol: "circle.fill", tint: color.color,
                                isOn: color == current) { set(color) })
    }
}

private extension NSMenuItem {
    /// From macOS 27, menus hide items' images unless told otherwise; these are there to find things by.
    func showsImage() {
        if #available(macOS 27, *) { preferredImageVisibility = .visible }
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}

/// A menu item that runs a command, showing its symbol (or swatch), checkmark and shortcut.
private final class CommandItem: NSMenuItem {
    private let run: () -> Void

    init(_ command: PaletteCommand) {
        run = command.action
        super.init(title: command.title, action: #selector(runCommand), keyEquivalent: "")
        target = self
        if let tint = command.tint {
            image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                NSColor(tint).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
        } else {
            image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        }
        showsImage()
        if let isOn = command.isOn { state = isOn ? .on : .off }
        toolTip = command.isOn == nil ? command.subtitle : nil
        if command.isDestructive {
            attributedTitle = NSAttributedString(string: command.title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        // Shown, as on any menu item; a context menu only acts on them while it's open.
        var key = command.shortcut ?? ""
        var modifiers: NSEvent.ModifierFlags = []
        for (symbol, flag) in [("⌘", NSEvent.ModifierFlags.command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)] where key.contains(symbol) {
            modifiers.insert(flag)
            key = key.replacing(symbol, with: "")
        }
        keyEquivalent = ["⌫": "\u{7F}", "⏎": "\r"][key] ?? key.lowercased()
        keyEquivalentModifierMask = modifiers
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func runCommand() { run() }
}
