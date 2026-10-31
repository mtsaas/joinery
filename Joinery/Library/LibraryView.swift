import SwiftUI

/// The window: a back panel with the tabs along its top, beside the window's buttons, and under them a raised surface
/// with whatever the tab in front shows: the library's data models, or a model's canvas and its controls.
struct LibraryView: View {
    @Bindable var library: Library
    /// The title bar's height, which the tab row matches so the window's buttons sit centered in it.
    @State private var titleBarHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            TabBar(library: library, height: titleBarHeight)
            Group {
                if let open = library.open {
                    ModelEditor(open: open)
                        .id(ObjectIdentifier(open))
                } else {
                    LibraryBrowser(library: library)
                }
            }
            // As far below the tabs as the surface is in from the window's sides.
            .padding(.top, Panel.inset - Panel.tabInset)
        }
        .background(Panel.color)
        .ignoresSafeArea(edges: .top)
        .background {
            Color.clear.ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if $0 > 0 { titleBarHeight = $0 } }
        }
        // For the Window menu and Mission Control. The window's title bar is hidden (see `JoineryApp`): the tabs are
        // in its place, and what each shows has its own controls, on its surface.
        .navigationTitle(library.open?.name ?? "Joinery")
        .alert("Something Went Wrong", isPresented: Binding { library.failure != nil } set: { if !$0 { library.failure = nil } }) {
            Button("OK") { library.failure = nil }
        } message: {
            Text(library.failure ?? "")
        }
    }
}

/// How the back panel and the surface on it fit together.
enum Panel {
    /// The gap between the surface and the window's edges, and between it and the tabs.
    static let inset: CGFloat = 8
    /// The space above and below the tabs in their row.
    static let tabInset: CGFloat = 4
    /// Grayer than any surface on it in light mode, and darker in dark, so they stand off it.
    static let color = Color(light: NSColor(white: 0.9, alpha: 1), dark: NSColor(white: 0.065, alpha: 1))
    /// The height of the capsules of controls floating along a surface's top.
    static let controlHeight: CGFloat = 36
    /// The gap between those controls and the surface's edges.
    static let controlInset = inset
    /// Concentric with the capsules in its top corners: their radius plus the gap between them.
    static let surfaceCornerRadius = controlHeight / 2 + controlInset
}

extension View {
    /// Raised off the back panel: rounded, edged and shadowed, and inset from the window's sides and bottom.
    func surface() -> some View {
        clipShape(.rect(cornerRadius: Panel.surfaceCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Panel.surfaceCornerRadius).strokeBorder(.separator.opacity(0.6))
            }
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .padding([.horizontal, .bottom], Panel.inset)
    }
}

/// The library, then the open models, one pill-shaped tab each, from the leading edge: an icon of the model and its
/// name, the one in front filled. Each closes with the × that takes its icon's place on hover, or ⌘W. Drag one to put
/// it elsewhere.
private struct TabBar: View {
    let library: Library
    let height: CGFloat

    /// Clear of the window's close, minimize and zoom buttons.
    static let leading: CGFloat = 78
    static let spacing: CGFloat = 4
    static let inset = Panel.tabInset
    /// The widest a tab gets; a long name is cut short in the middle.
    static let maxWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: Self.spacing) {
            Tab(isFront: library.open == nil, select: { library.selection = nil }) {
                Image(systemName: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            // A circle: as wide as it's tall.
            .frame(width: height - 2 * Self.inset)
            .help("All data models (⌘↑)")
            ForEach(library.tabs, id: \.url) { tab in
                ModelTab(tab: tab, isFront: tab === library.open, select: { library.selection = tab.url }, close: { library.close(tab) })
                    .frame(maxWidth: Self.maxWidth)
                    .help(tab.name)
                    .draggable(tab.url)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let dragged = urls.first, let index = library.tabs.firstIndex(where: { $0 === tab }) else { return false }
                        return library.moveTab(dragged, to: index)
                    }
            }
            Spacer(minLength: 0)
            Button("New Data Model", systemImage: "plus") { library.newModel(in: library.selection.flatMap(library.collection(of:))) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: height - 2 * Self.inset)
                .help("New data model, in a tab (⌘N)")
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, Panel.inset)
        .padding(.vertical, Self.inset)
        .frame(height: height)
    }

    /// A model's tab: its icon, or the × on hover, then its name.
    private struct ModelTab: View {
        let tab: OpenModel
        let isFront: Bool
        let select: () -> Void
        let close: () -> Void
        @State private var isHovered = false

        var body: some View {
            Tab(isFront: isFront, select: select, isHovered: $isHovered) {
                HStack(spacing: 6) {
                    ZStack {
                        TabIcon(model: tab.model).opacity(isHovered ? 0 : 1)
                        if isHovered {
                            Button("Close Tab", systemImage: "xmark", action: close)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .font(.caption2.weight(.bold))
                                .help("Close tab (⌘W)")
                        }
                    }
                    Text(tab.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // The icon as far in from the pill's leading end as from its top and bottom.
                .padding(.leading, TabIcon.inset)
                .padding(.trailing, 12)
            }
        }
    }

    /// A pill, filled in front, faintly on hover.
    private struct Tab<Content: View>: View {
        let isFront: Bool
        let select: () -> Void
        var isHovered: Binding<Bool>? = nil
        @ViewBuilder let content: Content
        @State private var hovering = false

        var body: some View {
            content
                .font(.callout.weight(isFront ? .medium : .regular))
                .foregroundStyle(isFront ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    Capsule()
                        .fill(isFront ? Self.frontFill : hovering ? Self.hoverFill : Self.fill)
                        .shadow(color: .black.opacity(isFront ? 0.1 : 0), radius: 1, y: 0.5)
                }
                .contentShape(.capsule)
                .onTapGesture(perform: select)
                .onHover { hovering = $0; isHovered?.wrappedValue = $0 }
        }

        /// Every tab is a pill: faint behind, a little stronger on hover, filled in front.
        static var fill: Color { Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06)) }
        static var hoverFill: Color { Color(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.1)) }
        static var frontFill: Color { Color(light: .white, dark: NSColor(white: 1, alpha: 0.16)) }
    }
}

/// A model in miniature, as a favicon: its tables, in their colors and where they are, in a pill concentric with the
/// tab's.
private struct TabIcon: View {
    let model: DataModel

    /// In from the tab's edges.
    static let inset: CGFloat = 4
    static let size = CGSize(width: 24, height: 16)

    var body: some View {
        Canvas { context, size in
            let frames = model.tables.map { (Metrics.frame(of: $0), $0.color) }
            guard let bounds = frames.map(\.0).reduce(nil, { $0?.union($1) ?? $1 }) else { return }
            let padding: CGFloat = 3
            let scale = min((size.width - 2 * padding) / bounds.width, (size.height - 2 * padding) / bounds.height)
            let offset = CGPoint(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            for (frame, color) in frames {
                let rect = CGRect(x: offset.x + (frame.minX - bounds.minX) * scale, y: offset.y + (frame.minY - bounds.minY) * scale,
                                  width: max(1, frame.width * scale), height: max(1, frame.height * scale))
                context.fill(Path(rect), with: .color(color.color))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.canvas)
        // Concentric with the tab: a pill whose ends are its ends, less the inset.
        .clipShape(.capsule)
    }
}

/// Edits a name in place, as Finder does: Return or clicking away keeps it, Escape cancels.
struct RenameField: View {
    @State var name: String
    /// Called once, with the new name or nil if cancelled.
    let done: (String?) -> Void
    @FocusState private var isFocused: Bool
    @State private var isFinished = false

    var body: some View {
        TextField("Name", text: $name)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { finish(name) }
            .onExitCommand { finish(nil) }
            .onChange(of: isFocused) { if !isFocused { finish(name) } }
    }

    /// Escape is followed by losing focus; only the first counts.
    private func finish(_ result: String?) {
        guard !isFinished else { return }
        isFinished = true
        done(result)
    }
}

/// A model's canvas, with its controls floating along its top, raised off the back panel.
struct ModelEditor: View {
    let open: OpenModel
    private var canvas: CanvasController { open.canvas }
    @State private var showsHistory = false
    @State private var showsSharing = false
    /// Where the canvas is in the window: inset on its surface, so its views' origins aren't its own.
    @State private var canvasOrigin = CGPoint.zero
    /// An earlier version shown instead of the model, read-only, from the version history.
    @State private var preview: VersionHistory.Preview?
    /// With an earlier version shown: it, it and now together with the changes marked, or now.
    @State private var comparison = Comparison.changes

    /// Lays out a version compared as `shown` is, and shows it as it is now if it's the version history's.
    private func layOut(_ target: OpenModel.Laid, as shown: DataModel, only: Set<Table.ID>? = nil) {
        guard let laid = open.layOut(target, as: shown, only: only), case .history(let url) = target, var preview else { return }
        if url == preview.version.url { preview.model = laid } else { preview.before = laid }
        self.preview = preview
    }

    var body: some View {
        // Compared with an earlier version, or two named versions compared, only the layout can change, and each table
        // moved is kept where it is in the version it's shown from. A review's version shows its own change, before
        // and after, not how it is now.
        let compared = open.named.compared(current: open.model)
        let (before, after): (DataModel?, DataModel) = preview.map { preview in preview.before.map { ($0, preview.model) } ?? (preview.model, open.model) }
            ?? (compared?.before, compared?.after ?? open.model)
        let diff = before.flatMap { comparison == .changes ? SchemaDiff(from: $0, to: after) : nil }
        let shown = before.map { comparison == .then ? $0 : diff?.model ?? after }
        let isComparing = before != nil
        // The versions compared, to lay out: earlier and later.
        let sides: (from: OpenModel.Laid, to: OpenModel.Laid)? = if let preview {
            preview.before != nil ? (.history(preview.version.beforeURL), .history(preview.version.url)) : (.history(preview.version.url), .current)
        } else if let named = open.named.comparison {
            (.named(named.from), .named(named.to))
        } else {
            nil
        }
        let model = Binding { shown ?? canvas.shown(open.model) } set: { new in
            guard isComparing, let sides else { return open.change(to: new) }
            canvas.stopFitting()
            if comparison == .then { return layOut(sides.from, as: new) }
            layOut(sides.to, as: new)
            // Tables removed since are only in the earlier version.
            if comparison == .changes, let diff { layOut(sides.from, as: new, only: Set(diff.tables.filter { $0.value == .removed }.keys)) }
        }
        CanvasView(model: model, canvas: canvas, diff: diff)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { canvasOrigin = $0 }
            .overlay(alignment: .top) {
                ZStack {
                    HStack(spacing: 8) {
                        ControlGroupGlass {
                            ZoomMenu(canvas: canvas, bounds: open.model.bounds)
                            Toggle("Version History", systemImage: "clock.arrow.circlepath", isOn: $showsHistory)
                                .help("Earlier versions of this data model: step through them with the arrow keys, and restore one")
                                .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                                    VersionHistory(open: open, preview: $preview)
                                        .frame(width: 340, height: 520)
                                }
                        }
                        ModelTitle(name: open.name) { Library.shared.rename(open.url, to: $0) }
                        Spacer()
                        ControlGroupGlass {
                            Button { showsSharing.toggle() } label: { ShareLabel(open: open) }
                                .help(open.session == nil ? "Share this data model live, for others to edit with you" : "Who's here, and how to invite others")
                                .popover(isPresented: $showsSharing, arrowEdge: .bottom) { SharePanel(open: open) }
                        }
                    }
                    // Editing tools, with nothing to edit while comparing.
                    ControlGroupGlass {
                        Button("Table", systemImage: "tablecells") { canvas.addTable(to: &model.wrappedValue) }
                            .help("Add a table (T)")
                            .disabled(isComparing)
                        Menu("Layout", systemImage: "rectangle.3.group") {
                            // The selection, if there is one; otherwise everything.
                            let selected = canvas.selectedTablesAndMembers(in: model.wrappedValue)
                            ForEach(DataModel.Layout.allCases) { layout in
                                Button(selected.isEmpty ? layout.title : "\(layout.title) (Selection)", systemImage: layout.symbol) {
                                    model.wrappedValue.arrange(layout, only: selected.isEmpty ? nil : selected)
                                    if selected.isEmpty { canvas.zoomToFit(model.wrappedValue.bounds) }
                                }
                            }
                            Divider()
                            Button("Untangle Selection", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                                canvas.untangleSelection(of: model)
                            }
                            .disabled(canvas.selectedTablesAndMembers(in: model.wrappedValue).isEmpty)
                        }
                        .help("Lay the selected tables out afresh, or every table with none selected; ⌘Z puts them back")
                        Toggle("Zip Tie", systemImage: "arrow.triangle.merge", isOn: Bindable(canvas).isTying)
                            .help("Zip-tie tool: drag across wires to tie them (Z)")
                        Toggle("Focus", systemImage: "scope", isOn: Binding { canvas.isFocusing } set: { _ in
                            canvas.toggleFocus(in: model.wrappedValue)
                        })
                        .help("Focus mode: fade everything but the selection and what it's joined to, until turned off (F)")
                        .disabled(isComparing)
                    }
                }
                .padding(Panel.controlInset)
            }
            .overlay(alignment: .top) {
                if let notice = open.notice {
                    Label(notice, systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect()
                        .padding(.top, 56)
                }
            }
            // Everyone else in a session: their pointers and selections.
            .overlay {
                PresenceLayer(open: open, tables: model.wrappedValue.tables, canvas: canvas)
            }
            .modifier(PresenceSharing(open: open, canvas: canvas, canvasOrigin: canvasOrigin))
            // At the bottom, clear of the version history's popover.
            .overlay(alignment: .bottom) {
                if let preview, preview.before != nil {
                    let when = "\(VersionHistory.title(of: preview.version.date)) at \(preview.version.date.formatted(date: .omitted, time: .shortened))"
                    ComparisonBar(comparison: $comparison, isReview: true, endsReview: false,
                                  caption: diff.map { "Reviewed \(when): \($0.summary)" } ?? "\(comparison == .then ? "Before" : "After") the change reviewed \(when)") {
                        self.preview = nil
                    }
                    .padding(.bottom, 20)
                } else if let preview {
                    let when = "\(VersionHistory.title(of: preview.version.date)) at \(preview.version.date.formatted(date: .omitted, time: .shortened))"
                    ComparisonBar(comparison: $comparison, isReview: false, endsReview: false,
                                  caption: diff.map { "\(when) to now: \($0.summary)" } ?? (comparison == .then ? when : "Now")) {
                        self.preview = nil
                    }
                    .padding(.bottom, 20)
                } else if let compared = open.named.comparison {
                    ComparisonBar(comparison: $comparison, isReview: true, endsReview: true, caption: nil,
                                  versions: (open.named.names, Binding { compared } set: { open.compare($0) })) {
                        open.endComparison()
                    }
                    .padding(.bottom, 20)
                }
            }
            // Comparing, it's only there to look at and lay out.
            .onChange(of: isComparing, initial: true) { canvas.isLayoutOnly = isComparing }
            // Filled from empty, or changing while compared (by an assistant, in a review), it stays in view, unless
            // panned or zoomed since.
            .onChange(of: model.wrappedValue.bounds) { old, new in
                if canvas.isFitted, old == nil || isComparing { canvas.zoomToFit(new) }
            }
            .focusedSceneValue(\.canvasController, canvas)
            .focusedSceneValue(\.model, model)
            .surface()
            #if DEBUG
            // Not cancelled if a step opens another model, closing this editor.
            .task { Task { await DebugHooks.script(model, canvas: canvas) } }
            .onReceive(NotificationCenter.default.publisher(for: .pickVersion)) { _ in showsHistory = true }
            .onReceive(NotificationCenter.default.publisher(for: .showSharing)) { _ in showsSharing = true }
            #endif
    }
}

/// Controls floating over the canvas, together in one piece of glass, as a toolbar's group would be.
private struct ControlGroupGlass<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .menuStyle(.borderlessButton)
            .imageScale(.large)
            .controlSize(.large)
            .padding(.horizontal, 10)
            .frame(height: Panel.controlHeight)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct ZoomMenu: View {
    let canvas: CanvasController
    let bounds: CGRect?

    var body: some View {
        // A text label, not an icon: it's the zoom itself that's shown.
        Menu {
            Button("Zoom In") { canvas.zoom(by: 1.25) }
            Button("Zoom Out") { canvas.zoom(by: 0.8) }
            Button("Zoom to Fit") { canvas.zoomToFit(bounds) }
            Divider()
            ForEach([0.5, 1, 2] as [CGFloat], id: \.self) { level in
                Button(Self.percent(level)) { canvas.zoom(by: level / canvas.zoom) }
            }
        } label: {
            Text(Self.percent(canvas.zoom))
        }
        .monospacedDigit()
        .fixedSize()
        .help("Zoom")
    }

    private static func percent(_ zoom: CGFloat) -> String {
        Double(zoom).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The open model's name, where the window's title would be; click it to rename it. Return or clicking away keeps the
/// new name, Escape doesn't.
private struct ModelTitle: View {
    let name: String
    let rename: (String) -> Void
    @State private var draft: String?
    @FocusState private var isFocused: Bool
    /// Watches for a click anywhere else while editing: the canvas doesn't take focus from the field, so it would stay.
    @State private var clickMonitor: Any?

    var body: some View {
        Group {
            if let draft {
                TextField("Name", text: Binding { draft } set: { self.draft = $0 })
                    .textFieldStyle(.plain)
                    .fixedSize()
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand { self.draft = nil }
                    .onChange(of: isFocused) { if !isFocused { commit() } }
                    .onAppear {
                        isFocused = true
                        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                            // The window's whole frame, title bar and all.
                            let hit = event.window?.contentView?.superview?.hitTest(event.locationInWindow)
                            if !(hit is NSText || hit is NSTextField) { commit() }
                            return event
                        }
                    }
                    .onDisappear {
                        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                        clickMonitor = nil
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            } else {
                Button(name) { draft = name }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .help("Rename")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .renameTitle)) { _ in draft = name }
        #endif
    }

    private func commit() {
        guard let draft else { return }
        self.draft = nil
        if draft != name { rename(draft) }
    }
}

#if DEBUG
extension Notification.Name {
    /// Starts renaming the open model, as a click on its title would.
    static let renameTitle = Notification.Name("JoineryRenameTitle")
}
#endif

/// Comparing two versions: which to show, what the difference is, and a way back to editing.
private struct ComparisonBar: View {
    @Binding var comparison: Comparison
    /// Reviewing a change, before and after it, rather than looking at an earlier version.
    let isReview: Bool
    /// The comparison open now, which ending stops, rather than a version kept in the version history.
    let endsReview: Bool
    let caption: String?
    /// Comparing named versions: their names, and which two are compared, to pick others.
    var versions: (names: [String], compared: Binding<NamedVersions.Comparison>)?
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if endsReview {
                Button(action: done) {
                    Label("End Comparison", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop comparing, to edit the data model as it is now. The named versions stay, and the change compared is kept in the version history too")
            } else {
                Image(systemName: isReview ? "plus.forwardslash.minus" : "clock.arrow.circlepath")
            }
            Picker("Compare", selection: $comparison) {
                ForEach(Comparison.allCases, id: \.self) { Text($0.title(isReview: isReview)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let versions {
                versionPicker("From", versions.names, versions.compared.from)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                versionPicker("To", versions.names, versions.compared.to)
            }
            if let caption { Text(caption).monospacedDigit() }
            if !endsReview {
                Button("Done", action: done)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to editing the data model as it is now (Escape)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect()
    }

    /// A menu of the named versions and now, the model as it is.
    private func versionPicker(_ title: String, _ names: [String], _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(names, id: \.self) { Text($0) }
            Divider()
            Text("Now").tag(NamedVersions.current)
        }
        .labelsHidden()
        .fixedSize()
        .help(title == "From" ? "The earlier version compared" : "The later version compared")
    }
}

/// Comparing: which side to show, or both with the changes marked.
private enum Comparison: CaseIterable {
    case then, changes, now

    func title(isReview: Bool) -> String {
        switch self {
        case .then: isReview ? "Before" : "Then"
        case .changes: "Changes"
        case .now: isReview ? "After" : "Now"
        }
    }
}

/// Shares this person's pointer, selection and what they're dragging with the session the model's in, if any.
private struct PresenceSharing: ViewModifier {
    let open: OpenModel
    let canvas: CanvasController
    /// Where the canvas is in the window: it reaches up under the toolbar, so its views' origins aren't its own.
    let canvasOrigin: CGPoint
    /// Where the pointer last hovered, in canvas points.
    @State private var hovered: CGPoint?
    /// When presence was last shared, to share it at most twenty times a second.
    @State private var lastShared = Date.distantPast
    /// Shares what's latest once the wait's over, when sharing it now was held back.
    @State private var trailing: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // Others' drags, shown as moving as they're made.
            .onChange(of: open.session?.peers ?? [:], initial: true) { _, peers in canvas.showDrags(of: peers.values) }
            .onAppear { open.onSessionChange = { [canvas] in canvas.dragsLanded() } }
            .onContinuousHover(coordinateSpace: .global) { phase in
                if case .active(let location) = phase {
                    hovered = canvas.canvasPoint(location - canvasOrigin)
                    share(throttled: true)
                } else {
                    hovered = nil
                    share()
                }
            }
            .onChange(of: canvas.selectedTables) { share() }
            .onChange(of: canvas.dragPointer) { _, new in
                // Hovering isn't heard while a button's down; afterwards it picks up from where the drag let go.
                if let new { hovered = new }
                share(throttled: true)
            }
            .onChange(of: canvas.dragOffset) { old, new in
                // Letting go: where it ended, then that it has, so others hold it exactly there until the change lands.
                if new == nil, let old { send(drag: old) }
                share(throttled: new != nil)
            }
            .onChange(of: canvas.marquee) { share(throttled: canvas.marquee != nil) }
    }

    /// Shares presence as it is now, or if `throttled` and it was shared less than 50 ms ago, once that's up, so the last
    /// of a movement is never left unsent.
    private func share(throttled: Bool = false) {
        let wait = 0.05 - Date.now.timeIntervalSince(lastShared)
        if throttled && wait > 0 {
            if trailing == nil {
                trailing = Task {
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    trailing = nil
                    share()
                }
            }
            return
        }
        send(drag: canvas.dragOffset)
    }

    private func send(drag: CGPoint?) {
        guard let session = open.session else { return }
        trailing?.cancel()
        trailing = nil
        lastShared = .now
        // A group's tables move with it, so they're what others are told are dragged.
        let selection = drag == nil ? canvas.selectedTables : canvas.selectedTablesAndMembers(in: open.model)
        session.share(Relay.Presence(cursor: canvas.dragPointer ?? hovered, selection: selection, drag: drag, marquee: canvas.marquee))
    }
}
