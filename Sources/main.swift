import AppKit

MainActor.assumeIsolated {

if CommandLine.arguments.contains("--self-test") {
    setbuf(stdout, nil)
    do {
        try runModelChecks()
        runGeometryChecks()
        try runEditingChecks()
        try runInteractionChecks()
        try runRichTextChecks()
        try runResponsivenessChecks()
        runPointerHandlerChecks()
        try renderInteractionSamples()
        try runManagerChecks()
        try runPetChecks()
        try runWorkflowWindowChecks()
        try runWorkflowChecks()
        print("PASS: inherited local prompt management regression checks")
        exit(0)
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--workflow-check") {
    setbuf(stdout, nil)
    app.setActivationPolicy(.prohibited)
    let directory = OpenEnvironment.dataDirectory
    Task {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await runAsyncWorkflowChecks(directory: directory, realModel: ProcessInfo.processInfo.environment["PROMPTSHELF_OPEN_TEST_MODEL"])
            exit(0)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    app.run()
    exit(0)
}
let instanceBundleID = OpenEnvironment.sandbox == nil ? OpenEnvironment.bundleID : Bundle.main.bundleIdentifier ?? OpenEnvironment.bundleID
if NSRunningApplication.runningApplications(withBundleIdentifier: instanceBundleID).contains(where: {
    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.run()

}
