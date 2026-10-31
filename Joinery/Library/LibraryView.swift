import SwiftUI

/// The window: a back panel with the tabs along its top, beside the window's buttons, and on it a raised surface with
/// the model in front, its canvas and controls, or with none, home: the library's sidebar and its data models.
struct LibraryView: View {
    @Bindable var library: Library
    /// The title bar's height, which the tab row matches so the window's buttons sit centered in it.
    @State private var titleBarHeight: CGFloat = 32

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let open = library.open {
                    ModelEditor(open: open)
                        .id(ObjectIdentifier(open))
                        .surface()
                } else {
                    LibraryBrowser(library: library)
                }
            }
            // Under the tabs, as far below them as they are below the window's top. Their previews open over it.
            .padding(.top, titleBarHeight)
            TabBar(library: library, height: titleBarHeight)
        }
        .background(Panel.color)
        .ignoresSafeArea(edges: .top)
        // Light catching the window's top edge, as it catches glass.
        .overlay { RoundedRectangle(cornerRadius: Panel.windowCornerRadius).sheen().ignoresSafeArea() }
        .background(TallTitleBar())
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
    /// A tab's height. The title bar is made taller than this (see `TallTitleBar`), and the tabs sit centered in it,
    /// as the window's buttons do, the space above them the same as the space below them to the surface.
    static let tabHeight: CGFloat = 28
    /// The theme's canvas, darkened, so the surfaces on it stand off it and it takes on the theme's tint.
    static var color: Color {
        Color(light: Themes.shared.light.canvas.blended(withFraction: 0.09, of: .black) ?? .gray,
              dark: Themes.shared.dark.canvas.blended(withFraction: 0.45, of: .black) ?? .black)
    }
    /// The window's own corners: measured from a snapshot, on macOS 26 with the title bar hidden.
    static let windowCornerRadius: CGFloat = 16
    /// The height of the capsules of controls floating along a surface's top.
    static let controlHeight: CGFloat = 36
    /// The gap between those controls and the surface's edges.
    static let controlInset = inset
    /// Each control's slot in its capsule, as a window toolbar's group spaces them: wider than its icon, so a wide
    /// symbol isn't crowding the next; and the capsule's margin at each end, beyond them.
    static let controlIconInset: CGFloat = 4
    static let controlItemSize = CGSize(width: 32, height: controlHeight - 2 * controlIconInset)
    /// The surface's top corners: concentric with the capsules in them, their radius plus the gap between them.
    static let surfaceCornerRadius = controlHeight / 2 + controlInset
    /// Its bottom corners: concentric with the window's, its radius less the gap between them.
    static let surfaceBottomCornerRadius = windowCornerRadius - inset

    /// Each corner follows what's nearest it: the controls in its top ones, the window's just outside its bottom ones.
    static let surfaceShape = UnevenRoundedRectangle(topLeadingRadius: surfaceCornerRadius, bottomLeadingRadius: surfaceBottomCornerRadius,
                                                     bottomTrailingRadius: surfaceBottomCornerRadius, topTrailingRadius: surfaceCornerRadius)
}

extension View {
    /// Raised off the back panel: rounded, edged and shadowed, and inset from the window's sides and bottom.
    func surface() -> some View {
        clipShape(Panel.surfaceShape)
            .overlay { Panel.surfaceShape.strokeBorder(.separator.opacity(0.6)) }
            .overlay { Panel.surfaceShape.sheen(0.4) }  // Fainter than the window's.
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .padding([.horizontal, .bottom], Panel.inset)
    }
}

extension InsettableShape {
    /// A glassy sheen, as light from above catches it: a bright edge along its top that fades out down its sides, and
    /// the faintest glow inside its top, gone a little way down. Subtle, and only to look at.
    /// `strength` scales it, 1 being the window's.
    func sheen(_ strength: Double = 1) -> some View {
        ZStack {
            strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.32 * strength), location: 0), .init(color: .white.opacity(0), location: 0.5)],
                                        startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)), lineWidth: 1)
            fill(LinearGradient(colors: [.white.opacity(0.06 * strength), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.06)))
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Dragging a tab along its group to reorder it: it follows the pointer, but past the group's ends, or up or down off
/// it, it's pulled back, more the further it goes, as a scroll view's content is past its edge; let go, it springs back
/// into its place.
enum TabDrag {
    /// The furthest a tab stretches past the group's ends, and up or down off it.
    static let reach = CGSize(width: 24, height: 12)

    /// `value` inside `range` as it is; outside it, pulled back towards it, never more than `reach` past.
    static func rubberBand(_ value: CGFloat, in range: ClosedRange<CGFloat>, reach: CGFloat) -> CGFloat {
        func pull(_ over: CGFloat) -> CGFloat { (1 - 1 / (over * 0.55 / reach + 1)) * reach }
        if value < range.lowerBound { return range.lowerBound - pull(range.lowerBound - value) }
        if value > range.upperBound { return range.upperBound + pull(value - range.upperBound) }
        return value
    }

    /// Where a tab whose middle is at `center` belongs among `count` tabs `width` wide, side by side from 0.
    static func slot(forCenter center: CGFloat, width: CGFloat, count: Int) -> Int {
        guard width > 0, count > 0 else { return 0 }
        return min(max(Int((center / width).rounded(.down)), 0), count - 1)
    }
}

/// An empty toolbar, so the title bar is as tall as a unified toolbar's, with the window's buttons centered in it:
/// room for the tabs to sit in it with space above and below. Its items, there are none, would show; the tabs do.
private struct TallTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class View: NSView {
        override func viewDidMoveToWindow() {
            guard let window, window.toolbar == nil else { return }
            window.toolbar = NSToolbar(identifier: "Joinery")
            window.toolbarStyle = .unifiedCompact
            // Not moved by any drag in the title bar, which would take the tabs' too: the tab row's empty space moves it.
            window.isMovable = false
        }
    }
}

/// A new model, in a tab.
private struct NewTabButton: View {
    let library: Library
    let size: CGFloat

    var body: some View {
        Button("New Data Model", systemImage: "plus") { library.newModel(in: library.selection.flatMap(library.collection(of:))) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: size, height: size)
            .help("New data model, in a tab (⌘N)")
    }
}

/// Home, then the open models together in one group on a subtle well, a tab each with an icon of the model, its name
/// and a ×; the one in front a raised glass pill in it. Drag a tab along the group to put it elsewhere: the others make way, and past the
/// group's ends it's pulled back (`TabDrag`).
///
/// Rest on a tab a moment and they peek: the row grows down over the surface, each model's tab showing the model as
/// it is now, until the pointer leaves the row. A preview is part of its tab: a click on either brings it forward,
/// and they stay open while the pointer's still there.
private struct TabBar: View {
    let library: Library
    let height: CGFloat

    /// Clear of the window's close, minimize and zoom buttons.
    static let leading: CGFloat = 78
    static let spacing: CGFloat = 4
    /// The widest a tab gets; a long name is cut short in the middle.
    static let maxWidth: CGFloat = 200
    /// How long the pointer rests on a tab before they peek.
    static let peekDelay = Duration.milliseconds(600)
    /// A peeked-at model's preview: its height, and its gap from the tab's sides and bottom, as the icon's from its
    /// leading end, so the preview's corners are concentric with the tab's.
    static let previewHeight: CGFloat = 96
    static let previewInset = (Panel.tabHeight - ModelIcon.size.height) / 2
    /// How much taller the row is while peeking.
    static let peekHeight = previewHeight + previewInset

    private var tabHeight: CGFloat { Panel.tabHeight }
    /// Between the group's edge and the tabs in it: its corners are theirs plus this, so they're concentric.
    static let groupInset: CGFloat = 3
    private var groupRadius: CGFloat { tabHeight / 2 + Self.groupInset }
    static let groupSpace = "tabGroup"
    static var groupShade: Color { Color(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.05)) }
    static var groupEdge: Color { Color(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.06)) }

    /// The tab being dragged: where the pointer took hold of it, from its leading edge, and where the pointer is now,
    /// both in the group.
    @State private var dragging: (url: URL, grab: CGPoint, location: CGPoint)?
    /// The width each tab has, sharing the group's evenly.
    @State private var tabWidth: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            // Home, the library, left of all the tabs: a circle, as wide as it's tall.
            Tab(isFront: library.open == nil, cornerRadius: tabHeight / 2, select: { _ in choose(nil) }, peek: {}) {
                Image(systemName: "house")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: tabHeight, height: tabHeight)
            .padding(.top, Self.groupInset)
            .help("Home: all data models (⌘↑)")
            if !library.tabs.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(library.tabs, id: \.url) { tab in
                        ModelTab(tab: tab, isFront: tab === library.open, isPeeking: library.isPeeking, height: tabHeight,
                                 select: { choose(tab.url) }, close: { library.close(tab) }, peek: peek)
                            .frame(maxWidth: Self.maxWidth)
                            .help(tab.name)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidth = $0 }
                            .offset(offset(of: tab))
                            .zIndex(dragging?.url == tab.url ? 1 : 0)
                            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.groupSpace))
                                .onChanged { drag(tab, $0) }
                                .onEnded { _ in withAnimation(.spring(duration: 0.35, bounce: 0.2)) { dragging = nil } })
                    }
                }
                .coordinateSpace(.named(Self.groupSpace))
                .padding(Self.groupInset)
                // A subtle well behind all the tabs; the glass is the tab in front's alone.
                // On the back panel's color, so peeking over the canvas, it doesn't show through.
                .background(RoundedRectangle(cornerRadius: groupRadius).fill(Self.groupShade).background(Panel.color, in: .rect(cornerRadius: groupRadius)))
                .overlay(RoundedRectangle(cornerRadius: groupRadius).strokeBorder(Self.groupEdge, lineWidth: 0.5))
            }
            Spacer(minLength: 0)
            NewTabButton(library: library, size: tabHeight)
                .padding(.top, Self.groupInset)
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, Panel.inset)
        .padding(.vertical, (height - tabHeight) / 2 - Self.groupInset)
        .frame(height: height + (library.isPeeking ? Self.peekHeight : 0), alignment: .top)
        // Tabs opening, closing, moving and coming to the front all move into place.
        .animation(.smooth(duration: 0.25), value: library.tabs.map(\.url))
        .animation(.smooth(duration: 0.25), value: library.open.map(ObjectIdentifier.init))
        // Behind the tabs along the title bar, the window's own: dragged, it moves; double-clicked, it zooms.
        .background(alignment: .top) {
            Color.clear
                .frame(height: height)
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
                .allowsWindowActivationEvents(true)
        }
        // Anywhere in the row, grown or not, keeps them peeking; leaving it stops.
        .contentShape(.rect)
        .onHover { if !$0 { setPeeking(false) } }
    }

    private func peek() {
        if !library.tabs.isEmpty { setPeeking(true) }
    }

    private func setPeeking(_ isPeeking: Bool) {
        guard library.isPeeking != isPeeking else { return }
        withAnimation(.smooth(duration: 0.3)) { library.isPeeking = isPeeking }
    }

    private func choose(_ url: URL?) {
        library.selection = url
    }

    /// Where a tab being dragged is drawn, from its place: following the pointer, pulled back past the group's ends.
    private func offset(of tab: OpenModel) -> CGSize {
        guard let dragging, dragging.url == tab.url, let index = library.tabs.firstIndex(where: { $0 === tab }) else { return .zero }
        let lastSlot = CGFloat(library.tabs.count - 1) * tabWidth
        let x = TabDrag.rubberBand(dragging.location.x - dragging.grab.x, in: 0...lastSlot, reach: TabDrag.reach.width)
        let y = TabDrag.rubberBand(dragging.location.y - dragging.grab.y, in: 0...0, reach: TabDrag.reach.height)
        return CGSize(width: x - CGFloat(index) * tabWidth, height: y)
    }

    /// Follows the pointer, bringing the tab to the front, and moves it among the others as its middle passes theirs.
    private func drag(_ tab: OpenModel, _ value: DragGesture.Value) {
        guard let index = library.tabs.firstIndex(where: { $0 === tab }) else { return }
        if dragging?.url != tab.url {
            choose(tab.url)
            dragging = (tab.url, CGPoint(x: value.startLocation.x - CGFloat(index) * tabWidth, y: value.startLocation.y), value.location)
        } else {
            dragging?.location = value.location
        }
        guard let dragging else { return }
        let center = dragging.location.x - dragging.grab.x + tabWidth / 2
        let slot = TabDrag.slot(forCenter: center, width: tabWidth, count: library.tabs.count)
        if slot != index { withAnimation(.smooth(duration: 0.25)) { _ = library.moveTab(tab.url, to: slot) } }
    }
}

/// A model's tab: its icon, its name and a × to close it; peeking, the model as it is now under them.
private struct ModelTab: View {
    let tab: OpenModel
    let isFront: Bool
    let isPeeking: Bool
    let height: CGFloat
    let select: () -> Void
    let close: () -> Void
    let peek: () -> Void
    @State private var preview: ModelPreviews.Preview?
    @State private var layouts = TextLayouts()
    @State private var isHovered = false
    @State private var isOverClose = false
    @State private var width: CGFloat = 0

    /// The icon as far in from the pill's leading end as from its top and bottom, so it's concentric with the pill.
    private var iconInset: CGFloat { (height - ModelIcon.size.height) / 2 }

    private var showsClose: Bool { isFront || isHovered }

    /// Where the × is, in the tab's own space, a little generous.
    private var closeFrame: CGRect {
        let size = ModelIcon.size.height
        return CGRect(x: width - iconInset - size, y: iconInset, width: size, height: size).insetBy(dx: -2, dy: -2)
    }

    var body: some View {
        // A click on the × closes it, worked out here from where it was: while peeking, the tab's own click wins
        // over the ×'s button.
        Tab(isFront: isFront, cornerRadius: height / 2, select: { showsClose && closeFrame.contains($0) ? close() : select() },
            peek: peek, isGrouped: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ModelIcon(model: tab.model)
                    Text(tab.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // As far in from the pill's trailing end as the icon is from its leading end: a circle the
                    // icon's height, concentric with the pill's end.
                    // On the tab in front, or while the pointer is on one; its space kept, so the name does not shift.
                    CloseButton(size: ModelIcon.size.height, isShown: showsClose, isHovered: isOverClose, action: close)
                }
                .padding(.horizontal, iconInset)
                .frame(height: height)
                if isPeeking {
                    // What the tab shows now, where it's scrolled and zoomed to.
                    ModelThumbnail(preview: preview, layouts: layouts,
                                   view: (tab.canvas.zoom, tab.canvas.offset, tab.canvas.viewSize))
                        .frame(maxWidth: .infinity)
                        .frame(height: TabBar.previewHeight)
                        .background(Theme.canvas)
                        .clipShape(.rect(cornerRadius: height / 2 - iconInset))
                        .padding([.horizontal, .bottom], iconInset)
                        .transition(.opacity)
                }
            }
        }
        // Hovered by where the pointer is, the × too, as the ×'s own hover isn't heard while peeking either.
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase {
                isHovered = true
                isOverClose = closeFrame.contains(point)
            } else {
                isHovered = false
                isOverClose = false
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.smooth(duration: 0.15), value: isHovered)
        .animation(.smooth(duration: 0.15), value: isOverClose)
        // Laid out and routed once each time they peek, not every frame of the row growing.
        .onChange(of: isPeeking, initial: true) { if isPeeking { preview = ModelPreviews.make(tab.model) } }
    }
}

/// A tab's ×, on the tab in front or a hovered one, a circle behind it when the × itself is hovered.
private struct CloseButton: View {
    let size: CGFloat
    let isShown: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .frame(width: size, height: size)
                .background(Circle().fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .help("Close tab (⌘W)")
        .accessibilityLabel("Close Tab")
    }
}

/// A pill: on its own (home), glass; in the tab group, clear on the group's subtle well, except the one in front,
/// which is glass, over a light fill, raised a little; on hover a fainter one fades in, as Safari's tabs lighten, the glass itself never changing,
/// so nothing flashes. Resting on it a moment calls `peek`.
private struct Tab<Content: View>: View {
    let isFront: Bool
    let cornerRadius: CGFloat
    /// Called with where it was clicked, in its own space.
    let select: (CGPoint) -> Void
    let peek: () -> Void
    /// In the tab group, which is glass already: none of its own.
    var isGrouped = false
    @ViewBuilder let content: Content
    @State private var hovering = false
    @State private var resting: Task<Void, Never>?

    static var frontFill: Color { Color(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.1)) }
    static var hoverFill: Color { Color(light: NSColor(white: 1, alpha: 0.4), dark: NSColor(white: 1, alpha: 0.05)) }

    var body: some View {
        content
            .font(.callout.weight(isFront ? .medium : .regular))
            .foregroundStyle(isFront ? .primary : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A pill while it's as tall as its corners are round, and a card of the same corners when it grows.
            .glassEffect(isFront ? .regular : isGrouped ? .identity : .clear, in: .rect(cornerRadius: cornerRadius))
            // Behind the glass, which shows it through.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isFront ? Self.frontFill : hovering ? Self.hoverFill : .clear)
                    .shadow(color: .black.opacity(isGrouped && isFront ? 0.15 : 0), radius: 1.5, y: 0.5)
            }
            .animation(.smooth(duration: 0.15), value: hovering)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .onTapGesture(coordinateSpace: .local, perform: select)
            .onHover { isHovering in
                hovering = isHovering
                resting?.cancel()
                guard isHovering else { return }
                resting = Task {
                    try? await Task.sleep(for: TabBar.peekDelay)
                    if !Task.isCancelled { peek() }
                }
            }
    }
}

/// A model in miniature, as a favicon: its tables, in their colors and where they are, straight on the tab.
struct ModelIcon: View {
    let model: DataModel?

    static let size = CGSize(width: 24, height: 16)

    var body: some View {
        Canvas { context, size in
            let frames = (model?.tables ?? []).map { (Metrics.frame(of: $0), $0.color) }
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
            #if DEBUG
            // Not cancelled if a step opens another model, closing this editor.
            .task { Task { await DebugHooks.script(model, canvas: canvas) } }
            .onReceive(NotificationCenter.default.publisher(for: .pickVersion)) { _ in showsHistory = true }
            .onReceive(NotificationCenter.default.publisher(for: .showSharing)) { _ in showsSharing = true }
            #endif
    }
}

/// Controls floating over the canvas, together in one piece of glass, as a toolbar's group would be. Not a
/// `ControlGroup`: outside a window toolbar that draws an older segmented control, not glass; and the window's toolbar
/// is where the tabs are.
struct ControlGroupGlass<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .labelStyle(IconSquare())
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .imageScale(.large)
            .padding(.horizontal, Panel.controlIconInset)
            .frame(height: Panel.controlHeight)
            .glassEffect(.regular, in: .capsule)
    }

    /// Each icon centered in the same slot, whatever its symbol's shape, so they line up and space evenly.
    private struct IconSquare: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.icon.frame(width: Panel.controlItemSize.width, height: Panel.controlItemSize.height)
        }
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
                // Text, not an icon square: room either side, as much as an icon's.
                .padding(.horizontal, Panel.controlIconInset * 2)
        }
        .monospacedDigit()
        .fixedSize()
        // Its arrow shown, unlike the icon menus': without, it reads as a label.
        .menuIndicator(.visible)
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
