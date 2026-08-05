import Cocoa
import FinderSync

/// The Finder Sync extension.
///
/// This class does as little as possible on purpose. A Finder Sync extension
/// runs sandboxed inside Finder's extension host, which means it cannot
/// usefully spawn the `rcsym` helper or read arbitrary paths. So it does
/// exactly two things: put items in the menu, and hand the selected paths to
/// the containing app over a custom URL scheme.
///
/// All the real work -- dialogs, validation, link creation -- happens in
/// `RightClickSymlink.app`, which is not sandboxed and can do those things
/// without fighting the powerbox.
class FinderSync: FIFinderSync {

    override init() {
        super.init()

        // Finder only offers extension menu items inside directories that have
        // been explicitly registered. Registering the root plus every mounted
        // volume is what makes the menu appear everywhere rather than in one
        // magic folder. This is the single most surprising part of the
        // FIFinderSync API and the usual reason a new extension "does nothing".
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        for volume in mounted {
            urls.insert(volume)
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")

        switch menuKind {
        case .contextualMenuForItems:
            // Right-clicked a file or folder: they are standing on the real
            // thing and need to say where the link goes.
            menu.addItem(
                withTitle: "Symlink To\u{2026}",
                action: #selector(symlinkTo(_:)),
                keyEquivalent: ""
            )

        case .contextualMenuForContainer:
            // Right-clicked empty space inside a folder: they are standing on
            // the destination and need to say what to point at.
            //
            // One entry covers both files and folders here, unlike Windows and
            // Linux, because NSOpenPanel can offer them simultaneously.
            menu.addItem(
                withTitle: "Symlink From\u{2026}",
                action: #selector(symlinkFrom(_:)),
                keyEquivalent: ""
            )

        default:
            // .contextualMenuForSidebar and .toolbarItemMenu -- nothing sensible
            // to offer.
            return nil
        }

        return menu
    }

    // MARK: - Actions

    @objc func symlinkTo(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty else { return }
        dispatch(action: "to", paths: items.map { $0.path })
    }

    @objc func symlinkFrom(_ sender: AnyObject?) {
        // For a container menu this is the folder being viewed.
        guard let dir = FIFinderSyncController.default().targetedURL() else { return }
        dispatch(action: "from", paths: [dir.path])
    }

    /// Hand off to the containing app.
    ///
    /// `URLComponents` handles percent-encoding, which matters more than it
    /// looks: paths routinely contain spaces, `#`, `?` and non-ASCII, and
    /// hand-rolled escaping of those is how this kind of bridge usually breaks.
    private func dispatch(action: String, paths: [String]) {
        var components = URLComponents()
        components.scheme = "rcsym"
        components.host = action
        components.queryItems = paths.map { URLQueryItem(name: "p", value: $0) }

        guard let url = components.url else {
            NSLog("RightClickSymlink: could not build URL for \(action)")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
