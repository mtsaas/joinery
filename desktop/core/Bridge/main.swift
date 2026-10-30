import Foundation
import JavaScriptEventLoop
import JavaScriptKit

// What the desktop app calls, from JavaScript (desktop/src/core.ts). Each call that can change anything is followed
// by `drainEvents()`, for what the shell has to do about it: redraw, save, send to the relay.

JavaScriptEventLoop.installGlobalExecutor()

/// The one open model, its scene and its session: WebAssembly has one thread, and the window one model.
enum App {
    nonisolated(unsafe) static let workspace = Workspace()
    nonisolated(unsafe) static let scene = Scene()
    nonisolated(unsafe) static let sessions = Sessions(workspace: workspace)
    /// A version picked in the history, shown instead of the model: compared with it now, or a review's, its change.
    /// `after` nil is the model as it is.
    nonisolated(unsafe) static var preview: (before: DataModel, after: DataModel?)?
    /// Comparing, which side is shown: "then", "changes" or "now".
    nonisolated(unsafe) static var side = "changes"
    static var isComparing: Bool { preview != nil || workspace.baseline != nil }
}

/// Comparing, nothing's edited from the canvas: it's only there to look at.
private func editable() throws(JSException) {
    if App.isComparing {
        throw JSException(message: App.preview != nil ? "Showing an earlier version: choose Done, or restore it, to edit."
                                                     : "Reviewing a change: choose End Review to edit.")
    }
}

private func failure(_ error: any Error) -> JSException {
    JSException(message: error.localizedDescription)
}

// MARK: The model

/// Opens a `.joinery` file's `model.json`, with a review's baseline, or "" for none.
@JS public func openModel(_ model: String, baseline: String) throws(JSException) {
    do {
        let decoder = JSONDecoder()
        let opened = try decoder.decode(DataModel.self, from: Data(model.utf8))
        let before = baseline.isEmpty ? nil : try decoder.decode(DataModel.self, from: Data(baseline.utf8))
        App.workspace.open(opened, baseline: before)
    } catch {
        throw failure(error)
    }
}

/// The open model as its file holds it, to save.
@JS public func modelFile() -> String {
    (try? App.workspace.model.fileData).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/// An empty model's file, for a new one.
@JS public func emptyModelFile() -> String {
    (try? DataModel().fileData).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/// Tables, columns and groups to draw, as JSON.
@JS public func scene() -> String { json(Scene.scene(App.workspace)) }

/// Wires, ports and ties at `time`, in seconds, as JSON. `offsets` is `{"tables": {id: [dx, dy]}, "ties": {…}}`.
/// `offsets` may also hold a `preview` of a drag in progress (see `Scene.previewing`).
@JS public func frame(_ time: Double, offsets: String, avoiding: Bool) -> String {
    let o = object(offsets)
    return json(App.scene.frame(App.workspace, time: time, tableOffsets: Edits.offsets(o["tables"]), tieOffsets: Edits.offsets(o["ties"]),
                                avoiding: avoiding, preview: o["preview"] as? [String: Any] ?? [:]))
}

/// Where on a group's edge a port nearest `x`, `y` would go: `{"side", "along", "point"}`, or "null".
@JS public func portSpot(_ group: String, _ x: Double, _ y: Double, offsets: String) -> String {
    guard let id = UUID(uuidString: group) else { return "null" }
    return json(Scene.portSpot(App.workspace, group: id, near: CGPoint(x: x, y: y), tableOffsets: Edits.offsets(object(offsets)["tables"]))
                ?? NSNull())
}

/// A port's socket within `reach` of `x`, `y`: `{"port", "isOutside", "center"}`, or "null".
@JS public func portSocketAt(_ x: Double, _ y: Double, reach: Double) -> String {
    json(App.scene.portSocket(App.workspace, at: CGPoint(x: x, y: y), within: reach) ?? NSNull())
}

/// The wire under `x`, `y`, within `tolerance` canvas points, or "null".
@JS public func wireAt(_ x: Double, _ y: Double, tolerance: Double) -> String {
    json(App.scene.hit(near: CGPoint(x: x, y: y), within: tolerance) ?? NSNull())
}

/// Makes an edit (see `Edits`), as one change and one undo. Returns `{"result": …}`.
@JS public func edit(_ name: String, arguments: String) throws(JSException) -> String {
    try editable()
    do { return try Edits.edit(name, object(arguments), in: App.workspace) } catch { throw failure(error) }
}

/// Zip-ties the wires a stroke crosses; returns the tie's ID, or "".
@JS public func zipTie(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String {
    guard !App.isComparing else { return "" }
    return App.scene.zipTie(App.workspace, from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))?.uuidString ?? ""
}

/// The selection as a clip, to copy.
@JS public func copy(_ selection: String) -> String { Edits.copy(object(selection), in: App.workspace) }

@JS public func undo() { if !App.isComparing { App.workspace.undo() } }
@JS public func redo() { if !App.isComparing { App.workspace.redo() } }

@JS public func markBaseline() { App.workspace.markBaseline() }
@JS public func endReview() {
    App.side = "changes"
    App.workspace.endReview()
    Events.post(["type": "changed"])
}

/// Shows a version from the history instead of the model, read-only: compared with the model as it is, or, a
/// review's (with `before`), as the change it was.
@JS public func showVersion(_ model: String, before: String) throws(JSException) {
    do {
        let decoder = JSONDecoder()
        let version = try decoder.decode(DataModel.self, from: Data(model.utf8))
        App.preview = before.isEmpty ? (version, nil) : (try decoder.decode(DataModel.self, from: Data(before.utf8)), version)
        App.side = "changes"
        Events.post(["type": "changed"])
    } catch {
        throw failure(error)
    }
}

/// Back to the model as it is, to edit.
@JS public func endPreview() {
    guard App.preview != nil else { return }
    App.preview = nil
    App.side = "changes"
    Events.post(["type": "changed"])
}

/// Comparing, which side to show: "then", "changes" or "now".
@JS public func setComparisonSide(_ side: String) {
    App.side = ["then", "now"].contains(side) ? side : "changes"
    Events.post(["type": "changed"])
}

/// A version's model, compared with the one open, as the review summary says it: "2 tables added".
@JS public func compare(_ before: String, _ after: String) -> String {
    let decoder = JSONDecoder()
    guard let a = try? decoder.decode(DataModel.self, from: Data(before.utf8)),
          let b = try? decoder.decode(DataModel.self, from: Data(after.utf8)) else { return "" }
    return SchemaDiff(from: a, to: b).summary
}

/// What's changed since the baseline, for the assistant's `get_changes`; "" with no review.
@JS public func changesReport() -> String {
    App.workspace.baseline.map { SchemaDiff(from: $0, to: App.workspace.model).report } ?? ""
}

/// How many tables the open model has.
@JS public func tableCount() -> Int { App.workspace.model.tables.count }

/// What the shell must do about the calls since the last time, as a JSON array of events.
@JS public func drainEvents() -> String { Events.drain() }

// MARK: Sessions

@JS public func hostSession(relay: String, name: String, title: String) throws(JSException) {
    do { try App.sessions.host(relay: relay, name: name, title: title) } catch { throw failure(error) }
}

@JS public func joinSession(link: String, name: String) throws(JSException) {
    do { try App.sessions.join(link: link, name: name) } catch { throw failure(error) }
}

@JS public func sessionConnected() { App.sessions.connected() }
@JS public func sessionDisconnected() { App.sessions.disconnected() }
@JS public func sessionReceived(_ base64: String) { App.sessions.received(Array(Data(base64Encoded: base64) ?? Data())) }
@JS public func sessionTick() { App.sessions.tick() }
@JS public func leaveSession() { App.sessions.leave() }

/// Where this person's pointer is and what they have selected, for others to see.
@JS public func sharePresence(_ presence: String) {
    let p = object(presence)
    App.sessions.share(Relay.Presence(cursor: p["cursor"] as? [Double], selection: p["selection"] as? [String] ?? [],
                                      drag: p["drag"] as? [Double], marquee: p["marquee"] as? [Double]))
}

// MARK: MCP

/// The library tools are the shell's: it keeps the library. They're called through `window.joineryHost.libraryTool`,
/// which returns a promise of the result's text, or rejects with why.
struct Assistant: MCPHost {
    func callLibraryTool(_ name: String, _ arguments: [String: Any]) async throws -> String {
        guard let host = JSObject.global.joineryHost.object, let call = host.libraryTool.function,
              let promise = call(this: host, name, json(arguments)).object else {
            throw Edits.Failure("Joinery's library isn't ready.")
        }
        do {
            return try await JSPromise(unsafelyWrapping: promise).value.string ?? ""
        } catch {
            throw Edits.Failure(error.thrownValue.object?.message.string ?? "\(error.thrownValue)")
        }
    }

    func edit(_ change: (inout DataModel) throws -> String) async throws -> String {
        var model = App.workspace.model
        let result = try change(&model)
        App.workspace.change(to: model, byAssistant: true)
        return result
    }
}

/// Answers one HTTP request to the MCP server, as its bytes in base64; returns the response's, or "" while the request
/// isn't whole.
@JS public func answerMCP(_ request: String) async -> String {
    guard let request = MCP.Request(Data(base64Encoded: request) ?? Data()) else { return "" }
    return await MCP.response(to: request, host: Assistant()).base64EncodedString()
}

/// The MCP tools, for Settings: `[{"name": …, "summary": …}]`.
@JS public func mcpTools() -> String { json(MCP.toolSummaries.map { ["name": $0.name, "summary": $0.summary] }) }
