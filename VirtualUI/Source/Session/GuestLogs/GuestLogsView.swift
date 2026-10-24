import SwiftUI
import VirtualCore
import VirtualWormhole

/// Follows a running virtual machine's logs through the Hypervisaur agent in the guest.
@MainActor
final class GuestLogStream: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    enum State: Equatable {
        case connecting
        case following
        case stopped(String)
    }

    @Published private(set) var lines = [Line]()
    @Published private(set) var state = State.connecting

    /// Older lines are dropped, so that following the logs for a long time doesn't use more and more memory.
    static let maximumLineCount = 10_000

    let virtualMachine: VBVirtualMachine

    private var client: GuestAgentClient?
    private var nextLineID = 0
    private var partialLine = ""

    init(virtualMachine: VBVirtualMachine) {
        self.virtualMachine = virtualMachine
    }

    func start() {
        guard client == nil else { return }

        state = .connecting
        let model = virtualMachine

        do {
            let client = try GuestAgentClient(virtualMachineAt: model.bundleURL, name: model.name)
            try client.open(GuestAgentOpenRequest(command: GuestLogs.followCommand(for: model.configuration.systemType)))
            try client.endInput()
            self.client = client
            state = .following

            /// Output is passed on through the main queue, which keeps it in order.
            let thread = Thread { [weak self] in
                var ending = "The virtual machine stopped."
                do {
                    reading: while let event = try client.nextEvent() {
                        switch event {
                        case .output(let data), .errorOutput(let data):
                            let text = String(decoding: data, as: UTF8.self)
                            DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(text) } }
                        case .exited:
                            ending = "The logs stopped."
                            break reading
                        case .failed(let message):
                            ending = message
                            break reading
                        }
                    }
                } catch {
                    ending = error.localizedDescription
                }
                DispatchQueue.main.async { [ending] in MainActor.assumeIsolated { self?.finish(ending) } }
            }
            thread.name = "GuestLogStream"
            thread.start()
        } catch {
            state = .stopped(error.localizedDescription)
        }
    }

    func stop() {
        guard let client else { return }
        self.client = nil
        try? client.terminate()
        client.close()
    }

    func clear() {
        lines.removeAll()
    }

    private func append(_ text: String) {
        let pieces = (partialLine + text).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        partialLine = String(pieces.last ?? "")

        let newLines = pieces.dropLast().map { piece -> Line in
            defer { nextLineID += 1 }
            return Line(id: nextLineID, text: String(piece))
        }
        lines.append(contentsOf: newLines)

        if lines.count > Self.maximumLineCount {
            lines.removeFirst(lines.count - Self.maximumLineCount)
        }
    }

    private func finish(_ message: String) {
        if !partialLine.isEmpty {
            append("\n")
        }
        client = nil
        state = .stopped(message)
    }
}

/// A window that shows a running virtual machine's logs as they're logged.
struct GuestLogsView: View {
    @StateObject private var stream: GuestLogStream
    @State private var filter = ""
    @State private var isPaused = false
    /// The lines that were shown when following was paused, so that the view stays still.
    @State private var pausedLines: [GuestLogStream.Line]?

    init(virtualMachine: VBVirtualMachine) {
        _stream = StateObject(wrappedValue: GuestLogStream(virtualMachine: virtualMachine))
    }

    private var visibleLines: [GuestLogStream.Line] {
        let lines = pausedLines ?? stream.lines
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollView in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .onChange(of: stream.lines.last?.id) { _, lastID in
                    guard !isPaused, filter.isEmpty || visibleLines.last?.id == lastID, let lastID else { return }
                    scrollView.scrollTo(lastID, anchor: .bottom)
                }
            }

            if case .stopped(let message) = stream.state {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { stream.start() }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 600, idealWidth: 960, maxWidth: .infinity, minHeight: 300, idealHeight: 600, maxHeight: .infinity)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isPaused.toggle()
                    pausedLines = isPaused ? stream.lines : nil
                } label: {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .help(isPaused ? "Show new log entries as they're logged" : "Stop showing new log entries for now")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visibleLines.map(\.text).joined(separator: "\n"), forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the log entries that are shown")

                Button {
                    stream.clear()
                    pausedLines = isPaused ? [] : nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the log entries that have been shown")
            }
        }
        .windowTitle("\(stream.virtualMachine.name) Logs")
        .windowStyleMask([.titled, .miniaturizable, .closable, .resizable])
        .task { stream.start() }
        .onDisappear { stream.stop() }
    }
}
