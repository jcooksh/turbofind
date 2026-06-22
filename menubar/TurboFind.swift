// ============================================================================
// TurboFind.swift — macOS menu-bar app shell for TurboFind.
//
// A status-bar (menu-bar) item with the TurboFind bolt. Click it → a popover
// drops down with the search UI, cursor already in the box: type → live results
// → click a result to reveal it in Finder. The left folder tree + right type
// filters come along (the popover embeds the existing web UI via WKWebView).
//
// The actual search engine is Python (turbovec + CLIP/MiniLM), which Swift can't
// run — so this app launches `serve.py` as a HIDDEN background child on loopback
// and the popover loads http://127.0.0.1:8765. You never see a browser/URL; the
// app owns the server's lifecycle (starts on launch, kills on quit).
//
// ─── BUILD ──────────────────────────────────────────────────────────────────
//   cd menubar && ./build.sh && open TurboFind.app
//   (build.sh compiles this + assembles a .app bundle with Info.plist so the
//    WKWebView is allowed to load the loopback HTTP server. Agent app: no Dock
//    icon, lives only in the menu bar.)
//
// Edit `Cfg` if your repo isn't at ~/turbofind.
// ============================================================================

import AppKit
import Carbon.HIToolbox    // RegisterEventHotKey — consuming global hot-key (Option+F)
import WebKit

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
    static let popover    = NSSize(width: 760, height: 580)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var server: Process?
    private var loaded = false
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
        let conf = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(origin: .zero, size: Cfg.popover), configuration: conf)
        webView.setValue(false, forKey: "drawsBackground")   // blend with popover
        let vc = NSViewController()
        vc.view = webView
        popover.contentViewController = vc
        popover.contentSize = Cfg.popover
        popover.behavior = .transient                 // closes when you click away
        popover.animates = true
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
        if !loaded, let url = URL(string: Cfg.serverURL) {
            webView.load(URLRequest(url: url))        // first open: load the UI
            loaded = true
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        focusSearchField()
    }

    /// Put the cursor straight in the search box so you can type immediately.
    private func focusSearchField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
            self?.webView.evaluateJavaScript(
                "var e=document.getElementById('q'); if(e){e.focus();e.select();}",
                completionHandler: nil)
        }
    }

    func popoverDidShow(_ note: Notification) { focusSearchField() }

    // -- right-click menu (quit / reindex) ----------------------------------

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
                self.loaded = false                       // force a fresh webview load
                self.startServer()                        // new code, fresh process
                if self.popover.isShown, let url = URL(string: Cfg.serverURL) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.webView.load(URLRequest(url: url)); self.loaded = true
                    }
                }
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
