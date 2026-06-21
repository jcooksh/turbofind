// ============================================================================
// Launcher.swift — TurboFind floating search bar (Spotlight/Raycast style)
//
// A standalone macOS agent app: a global hotkey (Option+Space) toggles a
// borderless floating panel with a search field. As you type it queries the
// TurboFind backend, lists results live, and Enter reveals the chosen file in
// Finder (selected + highlighted).
//
// ─── BUILD & RUN ────────────────────────────────────────────────────────────
//   Quick (single binary, agent app — no Dock icon):
//       swiftc Launcher.swift -o TurboFind -framework SwiftUI -framework AppKit
//       ./TurboFind
//
//   The Option+Space global hot-key uses Carbon RegisterEventHotKey, which
//   CONSUMES the chord system-wide and needs NO Accessibility permission. (If
//   another app already owns Option+Space, registration silently loses — change
//   the chord in registerGlobalHotKey().)
//
//   For a real distributable, wrap this in an Xcode app target / .app bundle
//   with LSUIElement=YES (agent app) and code-sign it.
//
// ─── CONFIGURE ──────────────────────────────────────────────────────────────
//   Edit `Config` below to point at your venv python + this repo. Choose the
//   backend: `.process` works out of the box; `.httpServer` (run `python
//   serve.py` first) keeps the model warm for instant, per-keystroke results.
// ============================================================================

import AppKit
import Carbon.HIToolbox    // RegisterEventHotKey — a consuming global hot-key
import SwiftUI

// MARK: - Configuration

enum Backend { case process, httpServer }

enum Config {
    /// Absolute path to the venv Python interpreter.
    static let pythonPath = "\(NSHomeDirectory())/turbofind/.venv/bin/python"
    /// Working directory of the TurboFind repo (so `import shared` resolves).
    static let repoDir = "\(NSHomeDirectory())/turbofind"
    /// Multimodal? Sets TURBOFIND_MULTI_MODAL for the backend.
    static let multiModal = false
    /// Which backend to use. `.httpServer` requires `python serve.py` running.
    static let backend: Backend = .process
    static let serverURL = "http://127.0.0.1:8765"
    /// Max results shown.
    static let resultLimit = 7
    /// Debounce before firing a query (seconds) — coalesces fast typing.
    static let debounce = 0.18
}

// MARK: - Model

/// One result row. Mirrors the JSON emitted by `search.py --json` / `serve.py`.
struct SearchResult: Decodable, Identifiable, Hashable {
    let path: String
    let score: Double
    let filename_match: Bool
    let exists: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

// MARK: - Backend abstraction

protocol SearchService {
    func search(_ query: String, limit: Int) async -> [SearchResult]
}

/// Spawns `python search.py --json <query>` and decodes stdout. Zero setup, but
/// pays the model cold-start on each call — best paired with debounce, or swap
/// to `HTTPBackend` for instant results.
struct ProcessBackend: SearchService {
    func search(_ query: String, limit: Int) async -> [SearchResult] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: Config.pythonPath)
                proc.currentDirectoryURL = URL(fileURLWithPath: Config.repoDir)
                // "--" ends option parsing so a query starting with '-' (e.g.
                // "-draft") is taken as the positional query, not an argparse flag.
                proc.arguments = ["search.py", "--json", "--no-color",
                                  "-k", String(limit), "--", query]
                var env = ProcessInfo.processInfo.environment
                if Config.multiModal { env["TURBOFIND_MULTI_MODAL"] = "1" }
                proc.environment = env

                let out = Pipe()
                proc.standardOutput = out
                // Discard stderr to /dev/null. Piping it to an UNDRAINED Pipe()
                // risks deadlock: a chatty cold model-load can exceed the pipe's
                // OS buffer, blocking the child before it closes stdout — then
                // readDataToEndOfFile() below would hang forever.
                proc.standardError = FileHandle.nullDevice

                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: [])
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: Self.decode(data))
            }
        }
    }

    static func decode(_ data: Data) -> [SearchResult] {
        (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
    }
}

/// Talks to the warm `serve.py` over loopback HTTP — instant, model stays loaded.
struct HTTPBackend: SearchService {
    func search(_ query: String, limit: Int) async -> [SearchResult] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Config.serverURL)/search?q=\(q)&k=\(limit)")
        else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
        } catch {
            return []
        }
    }
}

// MARK: - View model (debounced, cancellable)

final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [SearchResult] = []
    @Published var selection = 0

    private let service: SearchService =
        Config.backend == .httpServer ? HTTPBackend() : ProcessBackend()
    private var debounceTask: Task<Void, Never>?

    /// Called on every keystroke; debounces, then runs the (async) backend on a
    /// main-actor Task so all @Published mutations land on the main thread while
    /// the actual work happens off it (the backends suspend, never block UI).
    func queryChanged(_ text: String) {
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { results = []; selection = 0; return }
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Config.debounce * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let hits = await self.service.search(trimmed, limit: Config.resultLimit)
            if Task.isCancelled { return }
            self.results = hits
            self.selection = 0
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }

    /// Reveal the selected file in Finder (open window + highlight the file).
    func openSelected() {
        guard results.indices.contains(selection) else { return }
        let path = results[selection].path
        // The correct AppKit API: selectFile reveals AND highlights in Finder.
        // (`activateFileViewerSelecting([url])` is the modern multi-URL variant.)
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - SwiftUI view

struct SearchView: View {
    @ObservedObject var model: SearchViewModel
    var onClose: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search your files by meaning…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, new in model.queryChanged(new) }
                    .onSubmit { model.openSelected(); onClose() }
            }
            .padding(.horizontal, 20)
            .frame(height: 60)

            if !model.results.isEmpty {
                Divider().opacity(0.4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, r in
                                ResultRow(result: r, selected: idx == model.selection)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selection = idx
                                        model.openSelected(); onClose()
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: model.selection) { _, sel in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(sel) }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)            // frosted glass
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .onAppear { fieldFocused = true }
    }
}

struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(selected ? .white : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(result.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if result.filename_match {
                        Text("name").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.25)).clipShape(Capsule())
                    }
                }
                Text(result.folder)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.2f", result.score))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.9) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var icon: String {
        let ext = (result.path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg"].contains(ext) { return "photo" }
        if ["mp4", "mov", "m4v"].contains(ext) { return "film" }
        return "doc.text"
    }
}

// MARK: - Floating panel (borderless, non-activating, can become key for typing)

final class FloatingPanel: NSPanel {
    init(view: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .mainMenu + 1                 // above almost everything
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                     // SwiftUI draws its own shadow
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        contentView = view
    }
    // Borderless panels are not key by default; allow it so the field gets input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Global hot-key (Carbon) — consumes the chord system-wide

/// The Carbon hot-key callback is a plain C function and cannot capture Swift
/// context, so it calls through this trampoline (set once at launch; the Carbon
/// event handler runs on the main run-loop thread, so toggling UI here is safe).
private var hotKeyTrampoline: (() -> Void)?

private func turbofindHotKeyHandler(_ next: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    hotKeyTrampoline?()
    return noErr
}

// MARK: - App delegate: hotkey + panel lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private let model = SearchViewModel()
    private var localMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // agent app: no Dock icon
        registerGlobalHotKey()                  // Option+Space, consumed
        installLocalKeyMonitor()                // Esc / arrows while panel is key
    }

    /// Register Option+Space as a real, event-CONSUMING global hot-key via
    /// Carbon. An NSEvent global monitor is observe-only — it can't swallow the
    /// keystroke, so Option+Space would also reach the focused app and insert a
    /// non-breaking space. RegisterEventHotKey captures the chord and needs NO
    /// Accessibility permission.
    private func registerGlobalHotKey() {
        hotKeyTrampoline = { [weak self] in self?.toggle() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), turbofindHotKeyHandler,
                            1, &spec, nil, nil)
        let hkID = EventHotKeyID(signature: OSType(0x54424644) /* 'TBFD' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hkID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Local monitor only fires when our panel is key; safe to swallow here.
    private func installLocalKeyMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.hide(); return nil }                  // esc
            if event.keyCode == 125 { self.model.moveSelection(1); return nil }  // down
            if event.keyCode == 126 { self.model.moveSelection(-1); return nil } // up
            return event
        }
    }

    private func buildPanel() -> FloatingPanel {
        let root = SearchView(model: model, onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 60)
        host.autoresizingMask = [.width, .height]
        let p = FloatingPanel(view: host)
        p.setContentSize(NSSize(width: 640, height: 440))
        return p
    }

    private func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    private func show() {
        let p = panel ?? buildPanel()
        panel = p
        centerNearTop(p)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        panel?.orderOut(nil)
        model.query = ""
        model.results = []
    }

    /// Position the bar in the upper third of the active screen, like Spotlight.
    private func centerNearTop(_ p: NSPanel) {
        guard let screen = NSScreen.main else { p.center(); return }
        let f = screen.visibleFrame
        let size = p.frame.size
        let x = f.midX - size.width / 2
        let y = f.midY + f.height * 0.18
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func applicationWillTerminate(_ note: Notification) {
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
    }
}

// MARK: - Entry point (standalone executable, no @main needed)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
