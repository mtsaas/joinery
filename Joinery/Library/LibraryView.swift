import SwiftUI

/// The window: the library's browser, or when a model is open, its canvas, with a way back.
struct LibraryView: View {
    @Bindable var library: Library
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let open = library.open {
                ModelEditor(open: open) { library.selection = nil }
                    .id(ObjectIdentifier(open))
            } else {
                LibraryBrowser(library: library)
            }
        }
        // Undo belongs to the model it was done in, renamed or not.
        .onChange(of: library.open.map(ObjectIdentifier.init)) { undoManager?.removeAllActions() }
        .alert("Something Went Wrong", isPresented: Binding { library.failure != nil } set: { if !$0 { library.failure = nil } }) {
            Button("OK") { library.failure = nil }
        } message: {
            Text(library.failure ?? "")
        }
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

/// A model's canvas and toolbar.
struct ModelEditor: View {
    let open: OpenModel
    /// Back to the library.
    let close: () -> Void
    @State private var canvas = CanvasController()
    @State private var showsHistory = false
    @State private var showsSharing = false
    /// Where the canvas is in the window: it reaches up under the toolbar, so its views' origins aren't its own.
    @State private var canvasOrigin = CGPoint.zero
    /// An earlier version shown instead of the model, read-only, from the version history.
    @State private var preview: VersionHistory.Preview?
    /// With an earlier version shown: it, it and now together with the changes marked, or now.
    @State private var comparison = Comparison.changes
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // Compared with an earlier version, or in a review with how it was before the change, it can't be changed:
        // it's only there to look at.
        let base = preview?.model ?? open.baseline
        let diff = base.flatMap { comparison == .changes ? SchemaDiff(from: $0, to: open.model) : nil }
        let shown = base.map { comparison == .then ? $0 : diff?.model ?? open.model }
        let isComparing = base != nil
        let model = Binding { shown ?? canvas.shown(open.model) } set: { if !isComparing { open.change(to: $0) } }
        CanvasView(model: model, canvas: canvas, diff: diff)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { canvasOrigin = $0 }
            // Under the toolbar, which floats over it, but not the sidebar, so fitting the model fits what's visible.
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("All Data Models", systemImage: "chevron.left", action: close)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .help("Back to all data models (⌘↑)")
                }
                ToolbarItem(placement: .navigation) {
                    ZoomMenu(canvas: canvas, bounds: open.model.bounds)
                }
                ToolbarItem(placement: .navigation) {
                    Toggle("Version History", systemImage: "clock.arrow.circlepath", isOn: $showsHistory)
                        .help("Earlier versions of this data model: step through them with the arrow keys, and restore one")
                        .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                            VersionHistory(open: open, preview: $preview)
                                .frame(width: 340, height: 520)
                        }
                }
                ToolbarItem(placement: .navigation) {
                    ModelTitle(name: open.name) { Library.shared.rename(open.url, to: $0) }
                }
                .sharedBackgroundVisibility(.hidden)
                // Editing tools, with nothing to edit while comparing.
                ToolbarItemGroup(placement: .principal) {
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
                    .disabled(isComparing)
                    Toggle("Zip Tie", systemImage: "arrow.triangle.merge", isOn: Bindable(canvas).isTying)
                        .help("Zip-tie tool: drag across wires to tie them (Z)")
                        .disabled(isComparing)
                    Toggle("Focus", systemImage: "scope", isOn: Binding { canvas.isFocusing } set: { _ in
                        canvas.toggleFocus(in: model.wrappedValue)
                    })
                    .help("Focus mode: fade everything but the selection and what it's joined to, until turned off (F)")
                    .disabled(isComparing)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showsSharing.toggle() } label: { ShareLabel(open: open) }
                    .help(open.session == nil ? "Share this data model live, for others to edit with you" : "Who's here, and how to invite others")
                    .popover(isPresented: $showsSharing, arrowEdge: .bottom) { SharePanel(open: open) }
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // For the Window menu and Mission Control; shown by `ModelTitle` instead, to be renamed in place.
            .navigationTitle(open.name)
            .toolbar(removing: .title)
            .overlay(alignment: .top) {
                if let notice = open.notice {
                    Label(notice, systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect()
                        .padding(.top, 64)
                }
            }
            // Everyone else in a session: their pointers and selections.
            .overlay {
                PresenceLayer(open: open, tables: model.wrappedValue.tables, canvas: canvas)
                    .ignoresSafeArea(edges: .top)
            }
            .modifier(PresenceSharing(open: open, canvas: canvas, canvasOrigin: canvasOrigin))
            // At the bottom, clear of the version history's popover.
            .overlay(alignment: .bottom) {
                if let preview {
                    let when = "\(VersionHistory.title(of: preview.version.date)) at \(preview.version.date.formatted(date: .omitted, time: .shortened))"
                    ComparisonBar(comparison: $comparison, isReview: false,
                                  caption: diff.map { "\(when) to now: \($0.summary)" } ?? "\(comparison == .then ? when : "Now"), read-only") {
                        self.preview = nil
                    }
                    .padding(.bottom, 20)
                } else if open.baseline != nil {
                    ComparisonBar(comparison: $comparison, isReview: true,
                                  caption: diff.map { "Review: \($0.summary)" } ?? "\(comparison == .then ? "Before" : "After") the change, read-only") {
                        open.endReview()
                    }
                    .padding(.bottom, 20)
                }
            }
            // Comparing, it's only there to look at.
            .onChange(of: isComparing, initial: true) { canvas.isReadOnly = isComparing }
            // Filled from empty, or changing while compared (by an assistant, in a review), it stays in view, unless
            // panned or zoomed since.
            .onChange(of: model.wrappedValue.bounds) { old, new in
                if canvas.isFitted, old == nil || isComparing { canvas.zoomToFit(new) }
            }
            .onAppear { open.undoManager = undoManager }
            .onChange(of: undoManager) { open.undoManager = undoManager }
            .focusedSceneValue(\.canvasController, canvas)
            .focusedSceneValue(\.model, model)
            #if DEBUG
            // Not cancelled if a step opens another model, closing this editor.
            .task { Task { await DebugHooks.script(model, canvas: canvas) } }
            .onReceive(NotificationCenter.default.publisher(for: .pickVersion)) { _ in showsHistory = true }
            .onReceive(NotificationCenter.default.publisher(for: .showSharing)) { _ in showsSharing = true }
            #endif
    }
}

private struct ZoomMenu: View {
    let canvas: CanvasController
    let bounds: CGRect?

    var body: some View {
        Menu(Self.percent(canvas.zoom)) {
            Button("Zoom In") { canvas.zoom(by: 1.25) }
            Button("Zoom Out") { canvas.zoom(by: 0.8) }
            Button("Zoom to Fit") { canvas.zoomToFit(bounds) }
            Divider()
            ForEach([0.5, 1, 2] as [CGFloat], id: \.self) { level in
                Button(Self.percent(level)) { canvas.zoom(by: level / canvas.zoom) }
            }
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
                            // The window's whole frame, toolbar and all, as the field is in the toolbar.
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
    let caption: String
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isReview ? "plus.forwardslash.minus" : "clock.arrow.circlepath")
            Picker("Compare", selection: $comparison) {
                ForEach(Comparison.allCases, id: \.self) { Text($0.title(isReview: isReview)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(caption).monospacedDigit()
            if isReview {
                Button("End Review", action: done)
                    .help("Stop comparing: keep the data model as it is after the change, to edit, and forget how it was before")
            } else {
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
            // Letting go is always sent, so what others see of a drag doesn't stay behind.
            .onChange(of: canvas.dragOffset) { share(throttled: canvas.dragOffset != nil) }
            .onChange(of: canvas.marquee) { share(throttled: canvas.marquee != nil) }
    }

    private func share(throttled: Bool = false) {
        guard let session = open.session else { return }
        if throttled {
            guard Date.now.timeIntervalSince(lastShared) > 0.05 else { return }
            lastShared = .now
        }
        // A group's tables move with it, so they're what others are told are dragged.
        let selection = canvas.dragOffset == nil ? canvas.selectedTables : canvas.selectedTablesAndMembers(in: open.model)
        session.share(Relay.Presence(cursor: canvas.dragPointer ?? hovered, selection: selection,
                                     drag: canvas.dragOffset, marquee: canvas.marquee))
    }
}
