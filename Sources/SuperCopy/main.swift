import AppKit

let application = NSApplication.shared
if let flag = CommandLine.arguments.firstIndex(of: "--render-fixtures"), CommandLine.arguments.indices.contains(flag + 1) {
    do {
        try OffscreenVerification.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true))
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--self-test") {
    // Runs inside the real application run loop, exactly as the shipped app does.
    Task { @MainActor in exit(await SelfTest.run()) }
    application.run()
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
