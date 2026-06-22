// ============================================================================
// TurboFind.swift — native macOS menu-bar app for TurboFind.
//
// A status-bar (menu-bar) item with the TurboFind bolt. Click it (or press
// ⌥F anywhere) → a popover drops down with a NATIVE search UI, cursor already
// in the box: type → live results → ↓ into the list → Space = Quick Look,
// Enter / click = reveal in Finder. No browser, no WebView, no localhost URL.
//
// The search ENGINE is Python (turbovec + CLIP/MiniLM), which Swift can't run —
// so this app launches `serve.py` as a HIDDEN background child on loopback and
// talks to its JSON API (GET /search, /reveal, /preview) over 127.0.0.1. The
// app owns the engine's lifecycle (starts on launch, kills on quit).
//
// ─── BUILD ──────────────────────────────────────────────────────────────────
//   cd menubar && ./build.sh && open TurboFind.app
//   (Agent app: no Dock icon, lives only in the menu bar.)
//
// Edit `Cfg` if your repo isn't at ~/turbofind.
// ============================================================================

import AppKit
import Carbon.HIToolbox    // RegisterEventHotKey — consuming global hot-key (Option+F)

// The Carbon hot-key callback is a plain C function (no captured context); it
// calls through this trampoline, set once at launch and run on the main thread.
private var tfHotKeyAction: (() -> Void)?
private func tfHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                             _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    tfHotKeyAction?()
    return noErr
}

enum Cfg {
    static let repoDir   = "\(NSHomeDirectory())/turbofind"
    static let python    = "\(NSHomeDirectory())/turbofind/.venv/bin/python"
    static let serverURL = "http://127.0.0.1:8765"
    static let multiModal = true                      // set TURBOFIND_MULTI_MODAL
    static let popover    = NSSize(width: 600, height: 500)
}

// One search result, decoded straight from serve.py's /search JSON.
struct Hit: Decodable {
    let score: Double
    let filename_match: Bool
    let path: String
    let exists: Bool
    let added: Double
}

// ============================================================================
// Results table — custom NSTableView so we can route Space/Enter/Esc and "type
// to jump back to the search box" the way Finder/Spotlight do.
// ============================================================================
final class ResultsTableView: NSTableView {
    var onSpace:   (() -> Void)?
    var onEnter:   (() -> Void)?
    var onEscape:  (() -> Void)?
    var onUpAtTop: (() -> Void)?          // Up arrow while already on the first row
    var onDelete:  (() -> Void)?          // delete/backspace — back to the field, trim
    var onType:    ((String) -> Void)?    // a printable key — hand back to the field

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 49:          onSpace?();  return          // space  -> Quick Look
        case 36, 76:      onEnter?();  return          // return -> reveal in Finder
        case 53:          onEscape?(); return          // esc
        case 51:          onDelete?(); return          // delete -> edit the query
        case 125, 123, 124:                             // down / left / right
            super.keyDown(with: event); return          // let the table navigate
        case 126:                                       // up arrow
            if selectedRow <= 0 { onUpAtTop?(); return }
            super.keyDown(with: event); return          // otherwise move the selection
        default: break
        }
        // A printable character returns you to typing (like Finder). Exclude the
        // function-key private-use area (arrows etc. report U+F70x) so navigation
        // keys are never mistaken for text.
        if let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value < 0xF700,
           !CharacterSet.controlCharacters.contains(scalar) {
            onType?(chars); return
        }
        super.keyDown(with: event)
    }
}

// ============================================================================
// One row view: [ date ] [icon] [ name / path ] [score], built with explicit
// constraints so the name/path truncate cleanly inside the popover width.
// ============================================================================
final class ResultRow: NSView {
    private let date  = ResultRow.label(size: 11, mono: true,  color: .tertiaryLabelColor)
    private let icon  = ResultRow.label(size: 15, mono: false, color: .labelColor)
    private let name  = ResultRow.label(size: 13, mono: false, color: .labelColor)
    private let path  = ResultRow.label(size: 11, mono: false, color: .secondaryLabelColor)
    private let badge   = ResultRow.label(size: 9,  mono: false, color: .systemBlue)
    private let score = ResultRow.label(size: 11, mono: true,  color: .tertiaryLabelColor)

    private static func label(size: CGFloat, mono: Bool, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                      : NSFont.systemFont(ofSize: size)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        date.alignment = .right
        score.alignment = .right
        for v in [date, icon, name, path, badge, score] { addSubview(v) }
        // Let name/path shrink and truncate instead of forcing the row wider.
        for v in [name, path] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        badge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            date.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            date.centerYAnchor.constraint(equalTo: centerYAnchor),
            date.widthAnchor.constraint(equalToConstant: 58),

            icon.leadingAnchor.constraint(equalTo: date.trailingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),

            score.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            score.centerYAnchor.constraint(equalTo: centerYAnchor),
            score.widthAnchor.constraint(equalToConstant: 42),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            badge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: score.leadingAnchor, constant: -8),

            path.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            path.trailingAnchor.constraint(equalTo: score.leadingAnchor, constant: -8),
        ])
        // name's right edge must also stay clear of the score column.
        name.trailingAnchor.constraint(lessThanOrEqualTo: score.leadingAnchor, constant: -8).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()

    func configure(with h: Hit) {
        let n = (h.path as NSString).lastPathComponent
        name.stringValue = n
        path.stringValue = (h.path as NSString).deletingLastPathComponent
        icon.stringValue = ResultRow.icon(for: h.path)
        score.stringValue = String(format: "%.2f", h.score)
        date.stringValue = h.added > 0 ? ResultRow.df.string(from: Date(timeIntervalSince1970: h.added)) : "—"
        badge.stringValue = h.filename_match ? "name" : ""
        name.textColor = h.exists ? .labelColor : .tertiaryLabelColor
    }

    static func icon(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": return "📑"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "🖼️"
        case "mp4", "mov", "m4v", "avi", "mkv": return "🎬"
        default: return "📄"
        }
    }
}

// ============================================================================
// The search view controller — owns the field, type filters, and results table
// and talks to serve.py's JSON API.
// ============================================================================
final class SearchViewController: NSViewController, NSTableViewDataSource,
                                  NSTableViewDelegate, NSTextFieldDelegate {
    private let field  = NSTextField()
    private let scroll = NSScrollView()
    private let table  = ResultsTableView()
    private let status = NSTextField(labelWithString: "")
    private var filters: [NSButton] = []

    private var hits: [Hit] = []
    private var debounce: Timer?
    private var seq = 0                    // request id — drop stale responses
    private let session = URLSession(configuration: .ephemeral)

    private let kinds = [("text", "Text"), ("pdf", "PDF"), ("image", "Images"), ("video", "Video")]

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Cfg.popover))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        field.placeholderString = "Search by meaning…"
        field.font = NSFont.systemFont(ofSize: 18)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let filterRow = NSStackView()
        filterRow.orientation = .horizontal
        filterRow.spacing = 12
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        for (val, title) in kinds {
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(filtersChanged))
            b.state = .on
            b.identifier = NSUserInterfaceItemIdentifier(val)
            b.font = NSFont.systemFont(ofSize: 12)
            filters.append(b)
            filterRow.addArrangedSubview(b)
        }

        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.stringValue = "Type · ↓ into results · Space = Quick Look · Enter = open in Finder"
        status.translatesAutoresizingMaskIntoConstraints = false

        // results table
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.rowHeight = 52
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(onDoubleClick)
        if #available(macOS 11.0, *) { table.style = .plain }

        table.onSpace   = { [weak self] in self?.preview(self?.table.selectedRow ?? -1) }
        table.onEnter   = { [weak self] in self?.reveal(self?.table.selectedRow ?? -1) }
        table.onEscape  = { [weak self] in self?.focusSearch() }
        table.onUpAtTop = { [weak self] in self?.focusSearch() }
        table.onDelete  = { [weak self] in self?.deleteBackToField() }
        table.onType    = { [weak self] s in self?.typeIntoField(s) }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(field)
        view.addSubview(filterRow)
        view.addSubview(status)
        view.addSubview(scroll)

        let m: CGFloat = 14
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: m),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),

            filterRow.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            filterRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),

            status.centerYAnchor.constraint(equalTo: filterRow.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -m),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: filterRow.trailingAnchor, constant: 10),

            scroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m / 2),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m / 2),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -m / 2),
        ])
    }

    // -- focus --------------------------------------------------------------

    func focusSearch() {
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func typeIntoField(_ s: String) {
        field.stringValue += s
        moveCaretToEndAndSearch()
    }

    /// Delete/backspace while in the results list: trim the query and jump back
    /// to the field, the way Finder/Spotlight let you fix a search mid-list.
    private func deleteBackToField() {
        if !field.stringValue.isEmpty { field.stringValue.removeLast() }
        moveCaretToEndAndSearch()
    }

    private func moveCaretToEndAndSearch() {
        view.window?.makeFirstResponder(field)
        // NSRange offsets are UTF-16 units, not grapheme clusters — use NSString length.
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        schedule()
    }

    // -- search -------------------------------------------------------------

    func controlTextDidChange(_ obj: Notification) { schedule() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            if !hits.isEmpty {
                view.window?.makeFirstResponder(table)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                table.scrollRowToVisible(0)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            reveal(table.selectedRow >= 0 ? table.selectedRow : 0)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            schedule()
            return true
        default:
            return false
        }
    }

    @objc private func filtersChanged() { schedule() }

    private func schedule() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.runSearch()
        }
    }

    private func selectedTypes() -> [String] {
        let on = filters.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }
        return on.count == filters.count ? [] : on     // all checked => no filter
    }

    private func runSearch() {
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            seq += 1                     // invalidate any in-flight response so a late
            hits = []; table.reloadData() // result can't repopulate the cleared list
            status.stringValue = ""
            return
        }
        var comps = URLComponents(string: Cfg.serverURL + "/search")!
        var items = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "k", value: "40")]
        let types = selectedTypes()
        if !types.isEmpty { items.append(URLQueryItem(name: "types", value: types.joined(separator: ","))) }
        comps.queryItems = items
        guard let url = comps.url else { return }

        seq += 1
        let mine = seq
        let t0 = Date()
        status.stringValue = "searching…"
        let task = session.dataTask(with: url) { [weak self] data, _, err in
            let decoded: [Hit] = {
                guard let data = data else { return [] }
                return (try? JSONDecoder().decode([Hit].self, from: data)) ?? []
            }()
            DispatchQueue.main.async {
                guard let self = self, mine == self.seq else { return }   // drop stale
                if err != nil {
                    self.status.stringValue = "engine starting… keep typing"
                    return
                }
                self.hits = decoded
                self.table.reloadData()
                if !decoded.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                self.status.stringValue = "\(decoded.count) results · \(ms) ms"
            }
        }
        task.resume()
    }

    // -- reveal / preview ---------------------------------------------------

    private func hit(_ i: Int) -> Hit? { hits.indices.contains(i) ? hits[i] : nil }

    private func reveal(_ i: Int)  { ping("/reveal",  hit(i)?.path) }
    private func preview(_ i: Int) { ping("/preview", hit(i)?.path) }

    @objc private func onDoubleClick() { reveal(table.selectedRow) }

    /// Fire-and-forget GET to a serve.py action endpoint with a path param.
    private func ping(_ route: String, _ path: String?) {
        guard let path = path,
              var comps = URLComponents(string: Cfg.serverURL + route) else { return }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = comps.url else { return }
        session.dataTask(with: url).resume()
    }

    // -- table data ---------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = (tableView.makeView(withIdentifier: id, owner: self) as? ResultRow) ?? {
            let r = ResultRow(); r.identifier = id; return r
        }()
        v.configure(with: hits[row])
        return v
    }
}

// ============================================================================
// App delegate — menu-bar item, popover, hot-key, engine lifecycle, updates.
// ============================================================================
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let searchVC = SearchViewController()
    private var server: Process?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)         // menu-bar only, no Dock icon
        startServer()                                 // warm the engine in the background
        buildStatusItem()
        buildPopover()
        registerHotKey()                              // Option+F summons the panel
    }

    /// Option+F anywhere -> toggle the search popover. Carbon RegisterEventHotKey
    /// consumes the chord system-wide and needs no Accessibility permission.
    private func registerHotKey() {
        tfHotKeyAction = { [weak self] in
            guard let self else { return }
            if self.popover.isShown { self.popover.performClose(nil) } else { self.showPopover() }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), tfHotKeyHandler, 1, &spec, nil, nil)
        let hkID = EventHotKeyID(signature: OSType(0x54424644) /* 'TBFD' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(optionKey), hkID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // -- menu-bar item ------------------------------------------------------

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = menuBarIcon()
        button.image?.isTemplate = true               // adapts to light/dark menu bar
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Load the bolt mark from assets (SVG, macOS 13+); fall back to an SF Symbol.
    private func menuBarIcon() -> NSImage {
        let path = "\(Cfg.repoDir)/assets/logo-black.svg"
        if let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        return NSImage(systemSymbolName: "bolt.fill",
                      accessibilityDescription: "TurboFind") ?? NSImage()
    }

    // -- popover ------------------------------------------------------------

    private func buildPopover() {
        popover.contentViewController = searchVC
        popover.contentSize = Cfg.popover
        popover.behavior = .transient                 // closes when you click away
        popover.animates = false                       // instant (Spotlight-like) + lets
                                                       // popoverDidShow fire before keystrokes
        popover.delegate = self
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showRightClickMenu()
            return
        }
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        focusSearchField()
    }

    /// Put the cursor straight in the search box so you can type immediately.
    /// popoverDidShow is the authoritative moment (window is key by then) — it
    /// sets first responder synchronously, before any keystroke can arrive. This
    /// next-runloop pass is just a fast fallback for the already-key case.
    private func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
            self?.searchVC.focusSearch()
        }
    }

    func popoverDidShow(_ note: Notification) {
        popover.contentViewController?.view.window?.makeKey()
        searchVC.focusSearch()
    }

    // -- right-click menu (update / reindex / quit) -------------------------

    private func showRightClickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Update TurboFind…", action: #selector(update), keyEquivalent: "")
        menu.addItem(withTitle: "Re-index home (~)…", action: #selector(reindex), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TurboFind", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)          // show it under the item
        statusItem.menu = nil                         // reset so left-click opens the popover
    }

    // -- self-update --------------------------------------------------------

    /// `git pull` the repo, then bounce serve.py so the new Python code is live.
    /// Python changes (serve/ingest/search/shared) need no rebuild — the app
    /// just relaunches its engine child. Only changes to THIS Swift app require
    /// re-running build.sh (noted in the alert when the app sources moved).
    @objc private func update() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (ok, out, appChanged) = self.gitPull()
            DispatchQueue.main.async {
                if !ok {
                    self.showAlert("Update failed", out.isEmpty ? "git pull failed." : out)
                    return
                }
                if out.contains("Already up to date") {
                    self.showAlert("TurboFind", "Already up to date.")
                    return
                }
                var msg = "Updated to the latest.\nClick OK to restart the engine (takes a few seconds).\n\n" + out
                if appChanged {
                    msg += "\n\n⚠️ The menu-bar app itself changed — run "
                         + "`cd ~/turbofind/menubar && ./build.sh` and reopen to get those."
                }
                self.showAlert("TurboFind", msg)
                self.server?.terminate()                  // drop the old engine
                self.server = nil
                self.startServer()                        // new code, fresh process
            }
        }
    }

    /// Run `git pull --ff-only` in the repo. Returns (success, combined output,
    /// whether any menubar/ source changed). Reads the pipe before waiting so a
    /// large output can't fill the buffer and deadlock the child.
    private func gitPull() -> (Bool, String, Bool) {
        let before = self.gitHead()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = URL(fileURLWithPath: Cfg.repoDir)
        p.arguments = ["pull", "--ff-only"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "could not run git: \(error.localizedDescription)", false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        let appChanged = !before.isEmpty && self.gitFilesChanged(since: before).contains { $0.hasPrefix("menubar/") }
        return (p.terminationStatus == 0, out, appChanged)
    }

    private func gitHead() -> String { runGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func gitFilesChanged(since ref: String) -> [String] {
        runGit(["diff", "--name-only", ref, "HEAD"]).split(separator: "\n").map(String.init)
    }
    private func runGit(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = URL(fileURLWithPath: Cfg.repoDir)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func showAlert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
    }

    @objc private func reindex() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.currentDirectoryURL = URL(fileURLWithPath: Cfg.repoDir)
        p.arguments = ["ingest.py", "--once", NSHomeDirectory()]
        p.environment = serverEnv()
        try? p.run()                                  // fire-and-forget; the daemon would be nicer
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // -- python server lifecycle -------------------------------------------

    private func serverEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if Cfg.multiModal { env["TURBOFIND_MULTI_MODAL"] = "1" }
        return env
    }

    private func startServer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Cfg.python)
        p.currentDirectoryURL = URL(fileURLWithPath: Cfg.repoDir)
        p.arguments = ["serve.py"]
        p.environment = serverEnv()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()                               // if 8765 is already taken it exits;
            server = p                                // the existing server is used instead.
        } catch {
            NSLog("[TurboFind] could not launch serve.py: \(error)")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        server?.terminate()                           // stop the engine we started
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
