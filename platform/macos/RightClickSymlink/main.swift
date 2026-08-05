import Cocoa

/// The containing app.
///
/// Launched by the Finder Sync extension through the `rcsym://` URL scheme,
/// never by the user directly (it is an `LSUIElement`, so it has no Dock icon).
/// It owns the two things the sandboxed extension cannot do: show real save and
/// open panels, and run the `rcsym` helper.
///
/// Built with `swiftc` from `build.sh` rather than Xcode, so this is a
/// `main.swift` with explicit `NSApplication` setup instead of an `@main` type.

// MARK: - Helper invocation

enum Helper {
    /// Path to the bundled `rcsym` binary.
    static var url: URL? {
        Bundle.main.url(forResource: "rcsym", withExtension: nil)
    }

    /// Run `rcsym link` and return its stderr on failure.
    ///
    /// The Rust core stays the single source of truth for what a link is and
    /// when it is refused. Reimplementing any of that in Swift would mean two
    /// places to fix the next time a rule changes.
    static func link(target: String, into: String, name: String, relative: Bool) -> String? {
        guard let exe = url else {
            return "The rcsym helper is missing from the app bundle."
        }

        let process = Process()
        process.executableURL = exe
        var args = [
            "link",
            "--target", target,
            "--into", into,
            "--name", name,
            "--no-confirm",
        ]
        if relative { args.append("--relative") }
        process.arguments = args

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return "Could not start the helper: \(error.localizedDescription)"
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 { return nil }

        let message = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty
            ? "The helper failed with exit code \(process.terminationStatus)."
            : message.replacingOccurrences(of: "error: ", with: "")
    }
}

// MARK: - Panels

enum Panels {
    /// Ask what to point at.
    ///
    /// `canChooseFiles` and `canChooseDirectories` together are the reason
    /// macOS needs only one "Symlink From..." menu entry where Windows and
    /// Linux need two -- their native pickers cannot offer both at once.
    static func pickSource(startingAt dir: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Link to what?"
        panel.message = "Choose the file or folder the new link should point at."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false  // an alias is a valid thing to link to
        panel.directoryURL = URL(fileURLWithPath: dir)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Ask where the link goes and what to call it, in one panel.
    static func pickDestination(startingAt dir: String, defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Create link as"
        panel.message = "Choose where the link goes and what to call it."
        panel.prompt = "Create Link"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: dir)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func error(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not create the link"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func setupHelp() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Right Click Symlink is running"
        alert.informativeText = """
            This app has no window. It adds two entries to Finder's right-click \
            menu:

              \u{2022} Symlink To\u{2026}      right-click a file or folder
              \u{2022} Symlink From\u{2026}    right-click empty space in a folder

            If you do not see them, turn the extension on in:
            System Settings \u{203A} General \u{203A} Login Items & Extensions \u{203A} \
            Finder Extensions
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Whether a URL arrived. Double-clicking the app in Finder produces no
    /// URL, and showing setup instructions is more useful than doing nothing.
    private var handledAnything = false

    func application(_ application: NSApplication, open urls: [URL]) {
        handledAnything = true
        NSApp.activate(ignoringOtherApps: true)
        for url in urls {
            handle(url)
        }
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `application(_:open:)` arrives just after launch when we were started
        // by a URL. Give it a moment before deciding nothing is coming.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.handledAnything else { return }
            NSApp.activate(ignoringOtherApps: true)
            Panels.setupHelp()
            NSApp.terminate(nil)
        }
    }

    // MARK: Routing

    private func handle(_ url: URL) {
        let paths = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "p" }
            .compactMap { $0.value } ?? []

        guard !paths.isEmpty else { return }

        switch url.host {
        case "to":   paths.forEach(symlinkTo)
        case "from": symlinkFrom(container: paths[0])
        default:     Panels.error("Unrecognised request: \(url.absoluteString)")
        }
    }

    /// The user right-clicked the real thing; ask where the link goes.
    private func symlinkTo(target: String) {
        let targetURL = URL(fileURLWithPath: target)
        let startDir = targetURL.deletingLastPathComponent().path

        guard let dest = Panels.pickDestination(
            startingAt: startDir,
            defaultName: targetURL.lastPathComponent
        ) else { return }

        create(target: target, destination: dest)
    }

    /// The user right-clicked empty space; ask what to point at.
    ///
    /// `container` becomes the link's parent folder. It is never modified or
    /// replaced, which is what makes this direction incapable of destroying the
    /// folder it was invoked from.
    private func symlinkFrom(container: String) {
        guard let source = Panels.pickSource(startingAt: container) else { return }
        guard let dest = Panels.pickDestination(
            startingAt: container,
            defaultName: source.lastPathComponent
        ) else { return }

        create(target: source.path, destination: dest)
    }

    private func create(target: String, destination: URL) {
        // NSSavePanel pre-deletes nothing and the helper refuses to overwrite,
        // so a name collision surfaces as a clear error rather than data loss.
        if let error = Helper.link(
            target: target,
            into: destination.deletingLastPathComponent().path,
            name: destination.lastPathComponent,
            relative: false
        ) {
            Panels.error(error)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
