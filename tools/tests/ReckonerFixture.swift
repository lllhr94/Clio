import Darwin
import Foundation
import JavaScriptCore

private enum Workspace {
    static func resolve(_ path: String) -> URL? { nil }
}

struct ToolOutput {
    let text: String
    let isError: Bool

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

// SOURCE: RECKONER

@main
enum ReckonerFixture {
    static func stage(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func main() async throws {
        stage("Normal evaluation")
        let normal = await Reckoner.run("console.log('ready'); 6 * 7")
        precondition(!normal.isError && normal.text == "ready\n→ 42", normal.text)

        stage("Cancel a running evaluation")
        let cancelledAt = DispatchTime.now()
        let running = Task { await Reckoner.run("while (true) {}") }
        try await Task.sleep(for: .milliseconds(150))
        running.cancel()
        let cancelled = await running.value
        precondition(cancelled.isError && cancelled.text.contains("取消"), cancelled.text)
        precondition(DispatchTime.now().uptimeNanoseconds - cancelledAt.uptimeNanoseconds < 3_000_000_000)

        stage("Wait for the watchdog deadline")
        let timedOut = await Reckoner.run("while (true) {}")
        precondition(timedOut.isError && timedOut.text.contains("10 秒"), timedOut.text)
        stage("Evaluate again")
        let next = await Reckoner.run("21 * 2")
        precondition(!next.isError && next.text == "→ 42", next.text)
        print("JavaScript watchdog stops cancelled and timed-out workers.")
    }
}
