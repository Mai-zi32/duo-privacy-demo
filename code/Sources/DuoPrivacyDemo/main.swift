import AppKit
import Darwin

if ProcessInfo.processInfo.arguments.contains("--logic-self-test") {
    let passed = LogicSelfTest.run()
    print(passed ? "Attention gate self-test passed" : "Attention gate self-test failed")
    exit(passed ? 0 : 1)
}

if ProcessInfo.processInfo.arguments.contains("--screen-access-status") {
    let granted = CGPreflightScreenCaptureAccess()
    print(granted ? "Screen capture access granted" : "Screen capture access not granted")
    exit(granted ? 0 : 2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
