import AppKit
import Foundation
import Network

/// The Mac's side of the MCP server (`MCP`): listening on this Mac only, and the library tools. Edits go to the model
/// open in the window, appear as they're made, save themselves, and undo like any other.
@MainActor @Observable
final class MCPServer: @MainActor MCPHost {
    static let shared = MCPServer()
    /// Whether it runs, from Settings; on unless turned off.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "mcpServerEnabled") as? Bool ?? true }

    enum Status: Equatable {
        case off, starting, running
        /// Why it couldn't start, usually something else on the port.
        case failed(String)
    }

    private(set) var status = Status.off
    @ObservationIgnored private var listener: NWListener?

    /// Starts listening. If something else has the port, there's simply no server, and Settings says why; the app
    /// works the same.
    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // Only this Mac: nothing on the network can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: MCP.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            status = .failed("Couldn't set up the server.")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.receive(on: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = .running
                case .failed(let error), .waiting(let error):
                    self.status = .failed(error == .posix(.EADDRINUSE)
                        ? "Port \(MCP.port) is in use by another app, perhaps another copy of Joinery."
                        : error.localizedDescription)
                    self.listener?.cancel()
                    self.listener = nil
                default:
                    break
                }
            }
        }
        status = .starting
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = .off
    }


    private func receive(on connection: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                let buffer = buffer + (data ?? Data())
                if let request = MCP.Request(buffer) {
                    Task {
                        let response = await MCP.response(to: request, host: self)
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else if isComplete || error != nil || buffer.count > 8 << 20 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    // MARK: MCPHost

    @MainActor func callLibraryTool(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let library = Library.shared
        let all = library.models + library.collections.flatMap(\.models)
        switch name {
        case "list_models":
            let lines = all.map { url in
                let collection = library.collection(of: url).map { $0.lastPathComponent + "/" } ?? ""
                return "- " + collection + Library.name(of: url) + (url == library.selection ? " (open)" : "")
            }
            return lines.isEmpty ? "The library is empty." : lines.joined(separator: "\n")
        case "open_model":
            let wanted = (arguments["name"] as? String ?? "").lowercased()
            guard let url = all.first(where: { Library.name(of: $0).lowercased() == wanted }) else {
                throw ModelTools.Failure("There's no data model called \(arguments["name"] ?? ""). Use list_models to see them.")
            }
            library.selection = url
            return "Opened \(Library.name(of: url))."
        case "new_model":
            library.newModel(in: library.selection.flatMap(library.collection(of:)))
            if let url = library.selection, let wanted = arguments["name"] as? String, !wanted.isEmpty {
                library.rename(url, to: wanted)
            }
            return "Opened a new, empty data model: \(library.open?.name ?? "Untitled Data Model")."
        case "start_review":
            // Names can't hold these.
            let title = (arguments["title"] as? String ?? "").replacingOccurrences(of: ":", with: " –")
                .replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            library.newModel(in: try library.reviewsCollection(), named: title.isEmpty ? "Review" : title)
            guard let open = library.open else { throw ModelTools.Failure("Couldn't start a review: \(library.failure ?? "no data model opened").") }
            return "Opened \(open.name), a new, empty data model in Reviews. Next, draw the schema as it was before the change with create_tables, arrange it, then save it with save_version, named for the base, such as main."
        case "screenshot":
            return try await screenshot()
        case "start_sharing":
            guard let open = library.open else { throw ModelTools.Failure("No data model is open in Joinery. Use open_model or new_model first.") }
            if open.session != nil, !(open.session is SessionHost) {
                throw ModelTools.Failure("\(open.name) is a session joined from someone else; only its host can share it.")
            }
            let host = open.session as? SessionHost ?? SessionHost(model: open)
            open.session = host
            // The relay makes the room a moment after connecting, or can't be reached.
            for _ in 0..<100 where host.links == nil && open.session === host { try? await Task.sleep(for: .milliseconds(50)) }
            guard let links = host.links, open.session === host else {
                if open.session === host { open.session = nil; host.close() }
                throw ModelTools.Failure("Couldn't start sharing: \(host.status). The relay is \(SessionHost.relay.absoluteString), set in Joinery's Settings.")
            }
            let others = host.peers.isEmpty ? "No one else has joined yet." : "\(host.peers.count) others have joined."
            return "Sharing \(open.name). Edit link: \(links.edit) View link: \(links.view) Send them as you would a password; each is pasted into Join in Joinery's library. \(others)"
        default:
            throw ModelTools.Failure("There's no tool called \(name).")
        }
    }

    /// Saves a PNG of the window as it is, in whatever mode, and returns where.
    private func screenshot() async throws -> String {
        // ponytail: a fixed wait for wires and fades to settle after the last edit or compare.
        try? await Task.sleep(for: .milliseconds(600))
        guard let image = Self.windowImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ModelTools.Failure("Couldn't capture Joinery's window. Is it open and on screen?") }
        // Downloads is the one folder both the sandboxed app and the assistant's shell can reach. The sandbox's home
        // is its container, so the real one comes from the user record.
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        let name = (Library.shared.open?.name ?? "Joinery").replacingOccurrences(of: "/", with: "-")
        let url = home.appending(path: "Downloads/Joinery \(name) \(stamp).png")
        do { try png.write(to: url) } catch { throw ModelTools.Failure("Captured the window but couldn't save it: \(error.localizedDescription)") }
        return "Saved to \(url.path)"
    }

    /// The app's biggest visible window (or, `skippingMain`, the next biggest, such as Settings), with any of its
    /// others over it (popovers, menus) drawn where they are. CGWindowListCreateImage is obsoleted in the SDK, but an
    /// app may still capture its own windows without Screen Recording permission, so it's looked up at run time.
    static func windowImage(skippingMain: Bool = false) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let image = { (window: NSWindow) in
            unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
        }
        var windows = NSApp.windows.filter(\.isVisible).sorted { $0.orderedIndex > $1.orderedIndex }
        if skippingMain, let main = windows.max(by: { $0.frame.width < $1.frame.width }) { windows.removeAll { $0 === main } }
        guard let main = windows.max(by: { $0.frame.width < $1.frame.width }), let base = image(main) else { return nil }
        // Wide enough for what hangs over its edges, as a popover by the toolbar can.
        let over = windows.filter { $0 !== main && $0.frame.intersects(main.frame) }
        let bounds = over.reduce(main.frame) { $0.union($1.frame) }
        let scale = CGFloat(base.width) / main.frame.width
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for window in [main] + over {
            guard let picture = window === main ? base : image(window) else { continue }
            context.draw(picture, in: CGRect(x: (window.frame.minX - bounds.minX) * scale, y: (window.frame.minY - bounds.minY) * scale,
                                             width: window.frame.width * scale, height: window.frame.height * scale))
        }
        return context.makeImage()
    }

    @MainActor func withVersions(_ body: (inout VersionState) throws -> String) async throws -> String {
        guard let open = Library.shared.open else {
            throw ModelTools.Failure("No data model is open in Joinery. Use open_model, new_model or start_review first.")
        }
        var state = VersionState(model: open.model, named: open.named)
        let result = try body(&state)
        try open.setNamed(state.named)
        open.change(to: state.model, byAssistant: true)
        return result
    }

    @MainActor func edit(_ change: (inout DataModel) throws -> String) async throws -> String {
        guard let open = Library.shared.open else {
            throw ModelTools.Failure("No data model is open in Joinery. Use open_model or new_model first.")
        }
        var model = open.model
        let result = try change(&model)
        open.change(to: model, byAssistant: true)
        return result
    }
}
