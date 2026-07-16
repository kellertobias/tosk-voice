import AppKit
import Foundation

/// Launches and supervises a local TTS server process (Fish-Speech,
/// xtts-api-server, …) so the Server Voice engine has something to talk to.
/// The launch command is user-configured and runs through a login shell, so
/// PATH tools like uv/uvx work. The process is terminated when the user
/// stops it or the app quits.
@MainActor
final class ManagedTTSServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting…"
            case .running: "Running"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var recentOutput: [String] = []

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    var isRunning: Bool { state == .running || state == .starting }

    /// Starts the configured command and polls the endpoint until it answers.
    func start(command: String, healthURL: URL?) {
        stop()
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed("Enter a launch command first.")
            return
        }
        recentOutput = []
        state = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", trimmed]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n").map(String.init)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recentOutput.append(contentsOf: lines)
                if self.recentOutput.count > 40 { self.recentOutput.removeFirst(self.recentOutput.count - 40) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.healthTask?.cancel()
                self.healthTask = nil
                self.process = nil
                if case .failed = self.state { return }
                if self.state == .stopped { return }
                let hint = self.recentOutput.suffix(3).joined(separator: " · ")
                self.state = .failed(hint.isEmpty ? "The server exited (status \(finished.terminationStatus))." : hint)
            }
        }

        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process

        guard let healthURL else {
            // No endpoint to probe; assume up once the process survives briefly.
            healthTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.process != nil else { return }
                self.state = .running
            }
            return
        }
        healthTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(300)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if await Self.probe(healthURL) {
                    guard let self, self.process != nil else { return }
                    self.state = .running
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, let self, self.process != nil else { return }
            self.state = .failed("The server did not become reachable within five minutes.")
            self.stop()
        }
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        guard let process else {
            state = .stopped
            return
        }
        self.process = nil
        state = .stopped
        let pid = process.processIdentifier
        // Terminate the shell's children (the actual server) before the shell.
        let sweeper = Process()
        sweeper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweeper.arguments = ["-TERM", "-P", String(pid)]
        try? sweeper.run()
        process.terminate()
    }

    /// Any HTTP answer (even 404) proves the server is accepting connections.
    private static func probe(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}
