// ============================================================================
// TurboFind.swift — native macOS menu-bar app for TurboFind.
//
// A status-bar (menu-bar) item with the TurboFind bolt. Click it (or press
// ⌥F anywhere) → a popover drops down with a NATIVE search UI, cursor already
// in the box: type → live results → ↓ into the list → Space = Quick Look,
// Enter / click = reveal in Finder. No browser, no WebView, no localhost URL.
//
// THEMES: the look AND the layout are theme-driven (see `Theme` / `Themes`).
// "Default (Dark)" reproduces the original. Pick another from the bolt's
// right-click → Theme submenu; the choice persists in UserDefaults.
//
// The search ENGINE is Python (turbovec + CLIP/MiniLM), which Swift can't run —
// so this app launches `serve.py` as a HIDDEN background child on loopback and
// talks to its JSON API (GET /search, /reveal, /preview) over 127.0.0.1.
//
//   cd menubar && ./build.sh && open TurboFind.app
//   (Agent app: no Dock icon, lives only in the menu bar.)
// ============================================================================

import AppKit
import Carbon.HIToolbox    // RegisterEventHotKey — consuming global hot-key (Option+F)
import ServiceManagement   // SMAppService — launch at login (macOS 13+)
import Quartz              // QLPreviewPanel — native Quick Look (spacebar preview)

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
    static let multiModal = true
}

// One search result, decoded straight from serve.py's /search JSON.
struct Hit: Decodable {
    let score: Double
    let filename_match: Bool
    let path: String
    let exists: Bool
    let added: Double
}

extension NSColor {
    convenience init(_ hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green:    CGFloat((hex >> 8) & 0xff) / 255,
                  blue:     CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// ============================================================================
// Theme model — colours AND layout. A theme is a complete look: appearance,
// palette, fonts, the row layout, the search-field style, popover size.
// ============================================================================
enum DatePos { case leftColumn, right, hidden }
enum SearchStyle { case rounded, underline, pill, prompt, centered }
enum DateFmt { case long, short, isoBracket }

struct LayoutSpec {
    var showIcon = true
    var iconSize: CGFloat = 15
    var datePos: DatePos = .leftColumn
    var dateFmt: DateFmt = .long
    var datePill = false
    var showPath = true
    var inline = false          // name + path on one line vs stacked
    var showScore = true
    var showBadge = true
    var nameOnly = false        // render just the filename
    var centered = false        // centre the row content
}

struct Theme {
    let id: String
    let name: String
    let dark: Bool
    let popover: NSSize
    // palette
    let bg: NSColor
    let fieldBg: NSColor
    let fieldText: NSColor
    var accent: NSColor         // selection tint + flourishes (user-overridable)
    let title: NSColor
    let subtitle: NSColor
    let faint: NSColor
    // type
    let mono: Bool
    let titleSize: CGFloat
    let pathSize: CGFloat
    let searchSize: CGFloat
    // layout
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let showFilters: Bool
    let searchStyle: SearchStyle
    let spec: LayoutSpec
    var translucent: Bool = false      // frosted/vibrant background (like Spotlight)

    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
             : NSFont.systemFont(ofSize: size, weight: weight)
    }
}

enum Themes {
    static let key = "turbofind.theme"

    static let all: [Theme] = [
        // 0. Apple / Sonoma — the default: frosted .menu vibrancy, SF type,
        //    segmented-pill filters, accent-tinted selection.
        Theme(id: "apple", name: "Apple (Sonoma)", dark: true,
              popover: NSSize(width: 660, height: 500),
              bg: NSColor(0x1c1c1e),
              fieldBg: NSColor(white: 1, alpha: 0.07),
              fieldText: .white,
              accent: NSColor(0x0a84ff),
              title: NSColor(0xf5f5f7),
              subtitle: NSColor(0xa1a1a6),
              faint: NSColor(0x6e6e73),
              mono: false, titleSize: 15.5, pathSize: 12, searchSize: 23,
              rowHeight: 54, rowSpacing: 3, showFilters: true, searchStyle: .centered,
              spec: LayoutSpec(showIcon: true, iconSize: 26, datePos: .right, dateFmt: .short,
                               datePill: false, showPath: true, inline: false,
                               showScore: false, showBadge: true),
              translucent: true),

        Theme(id: "apple-light", name: "Apple (Light)", dark: false,
              popover: NSSize(width: 660, height: 500),
              bg: NSColor(0xfcfcfd),
              fieldBg: NSColor(white: 0, alpha: 0.045),
              fieldText: NSColor(0x1d1d1f),
              accent: NSColor(0x0a84ff),
              title: NSColor(0x1d1d1f),
              subtitle: NSColor(0x6e6e73),
              faint: NSColor(0x9a9aa0),
              mono: false, titleSize: 15.5, pathSize: 12, searchSize: 23,
              rowHeight: 54, rowSpacing: 3, showFilters: true, searchStyle: .centered,
              spec: LayoutSpec(showIcon: true, iconSize: 26, datePos: .right, dateFmt: .short,
                               datePill: false, showPath: true, inline: false,
                               showScore: false, showBadge: true),
              translucent: true),

        // 1. The original.
        Theme(id: "default", name: "Default (Dark)", dark: true,
              popover: NSSize(width: 600, height: 500),
              bg: NSColor(0x0f1115), fieldBg: NSColor(0x171a21), fieldText: .white,
              accent: NSColor(0x3b82f6), title: NSColor(0xe8eaed),
              subtitle: NSColor(0x9aa0aa), faint: NSColor(0x6b7280),
              mono: false, titleSize: 13, pathSize: 11, searchSize: 18,
              rowHeight: 52, rowSpacing: 3, showFilters: true, searchStyle: .rounded,
              spec: LayoutSpec(showIcon: true, iconSize: 15, datePos: .leftColumn,
                               dateFmt: .long, showPath: true, inline: false,
                               showScore: true, showBadge: true)),

        // 2. Light, dense, single-line — like a mail list.
        Theme(id: "paper", name: "Paper (Light)", dark: false,
              popover: NSSize(width: 560, height: 520),
              bg: NSColor(0xfaf9f6), fieldBg: NSColor(0xffffff), fieldText: NSColor(0x1c1917),
              accent: NSColor(0xc2410c), title: NSColor(0x1c1917),
              subtitle: NSColor(0x78716c), faint: NSColor(0xa8a29e),
              mono: false, titleSize: 13, pathSize: 11, searchSize: 17,
              rowHeight: 30, rowSpacing: 1, showFilters: true, searchStyle: .underline,
              spec: LayoutSpec(showIcon: true, iconSize: 13, datePos: .right,
                               dateFmt: .short, showPath: true, inline: true,
                               showScore: false, showBadge: false)),

        // 3. Spotlight — big centred field, icon-forward, no score/date.
        Theme(id: "spotlight", name: "Spotlight", dark: true,
              popover: NSSize(width: 680, height: 460),
              bg: NSColor(0x1c1c1e), fieldBg: NSColor(0x2c2c2e), fieldText: .white,
              accent: NSColor(0x0a84ff), title: .white,
              subtitle: NSColor(0x98989d), faint: NSColor(0x636366),
              mono: false, titleSize: 16, pathSize: 11, searchSize: 23,
              rowHeight: 56, rowSpacing: 4, showFilters: true, searchStyle: .centered,
              spec: LayoutSpec(showIcon: true, iconSize: 28, datePos: .right, dateFmt: .short,
                               showPath: true, inline: false,
                               showScore: false, showBadge: false),
              translucent: true),

        // 4. Terminal — monospace, green-on-black, ultra-dense, [iso] dates.
        Theme(id: "terminal", name: "Terminal", dark: true,
              popover: NSSize(width: 640, height: 480),
              bg: NSColor(0x03120a), fieldBg: NSColor(0x041c0f), fieldText: NSColor(0x4ade80),
              accent: NSColor(0x22c55e), title: NSColor(0x4ade80),
              subtitle: NSColor(0x16a34a), faint: NSColor(0x166534),
              mono: true, titleSize: 12, pathSize: 11, searchSize: 14,
              rowHeight: 22, rowSpacing: 0, showFilters: true, searchStyle: .prompt,
              spec: LayoutSpec(showIcon: false, datePos: .leftColumn, dateFmt: .isoBracket,
                               showPath: true, inline: true,
                               showScore: true, showBadge: false)),

        // 5. Cards — roomy, purple accent, date pill, big rows.
        Theme(id: "cards", name: "Cards", dark: true,
              popover: NSSize(width: 640, height: 560),
              bg: NSColor(0x111317), fieldBg: NSColor(0x1b1f27), fieldText: .white,
              accent: NSColor(0x3b82f6), title: NSColor(0xf3f4f6),
              subtitle: NSColor(0x9ca3af), faint: NSColor(0x6b7280),
              mono: false, titleSize: 14, pathSize: 11, searchSize: 21,
              rowHeight: 66, rowSpacing: 6, showFilters: true, searchStyle: .pill,
              spec: LayoutSpec(showIcon: true, iconSize: 24, datePos: .right,
                               dateFmt: .short, datePill: true, showPath: true,
                               inline: false, showScore: true, showBadge: true)),

        // 6. Minimal — light, centred, filename only, lots of air.
        Theme(id: "minimal", name: "Minimal", dark: false,
              popover: NSSize(width: 520, height: 440),
              bg: NSColor(0xffffff), fieldBg: NSColor(0xf3f4f6), fieldText: NSColor(0x111827),
              accent: NSColor(0x111827), title: NSColor(0x111827),
              subtitle: NSColor(0x6b7280), faint: NSColor(0xd1d5db),
              mono: false, titleSize: 16, pathSize: 11, searchSize: 21,
              rowHeight: 40, rowSpacing: 2, showFilters: false, searchStyle: .centered,
              spec: LayoutSpec(showIcon: false, datePos: .hidden,
                               showPath: false, showScore: false, showBadge: false,
                               nameOnly: true, centered: true)),
    ]

    static func byId(_ id: String) -> Theme? { all.first { $0.id == id } }
    static func current() -> Theme {
        byId(UserDefaults.standard.string(forKey: key) ?? "apple") ?? byId("apple") ?? all[0]
    }

    // -- accent override (the "purple" in Cards, recolourable) ---------------
    static let accentKey = "turbofind.accent"
    static let accents: [(String, UInt32)] = [
        ("Blue", 0x0a84ff), ("Purple", 0xbf5af0), ("Teal", 0x3bc7e0),
        ("Green", 0x30d158), ("Orange", 0xff9f0a), ("Pink", 0xff375f),
    ]
    /// User-chosen accent, or nil to use the theme's own accent.
    static func currentAccent() -> NSColor? {
        guard let s = UserDefaults.standard.string(forKey: accentKey),
              let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(v)
    }
}

// ============================================================================
// Search field — NSTextField doesn't vertically centre single-line text in a
// tall frame (it rides to the top) and bezel-less fields have no left inset.
// This cell centres the text on the Y axis and pads bezel-less fields.
// ============================================================================
final class VCenterTextFieldCell: NSTextFieldCell {
    private func adjusted(_ rect: NSRect) -> NSRect {
        var r = rect
        if !isBezeled { r.origin.x += 11; r.size.width -= 22 }   // breathing room
        let th = cellSize(forBounds: r).height
        if th < r.height {                                        // centre vertically
            r.origin.y += (r.height - th) / 2
            r.size.height = th
        }
        return r
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: adjusted(rect))
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: adjusted(cellFrame), in: controlView)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjusted(rect), in: controlView, editor: editor,
                   delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: adjusted(rect), in: controlView, editor: editor,
                     delegate: delegate, start: start, length: length)
    }
}

final class SearchField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VCenterTextFieldCell.self }
        set { }
    }
}

// ============================================================================
// Results table — routes Space/Enter/Esc/Delete and "type to jump back".
// ============================================================================
final class ResultsTableView: NSTableView {
    var onSpace:   (() -> Void)?
    var onEnter:   (() -> Void)?
    var onEscape:  (() -> Void)?
    var onUpAtTop: (() -> Void)?
    var onDelete:  (() -> Void)?
    var onType:    ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 49:          onSpace?();  return          // space  -> Quick Look
        case 36, 76:      onEnter?();  return          // return -> reveal in Finder
        case 53:          onEscape?(); return          // esc
        case 51:          onDelete?(); return          // delete -> edit the query
        case 125, 123, 124:
            super.keyDown(with: event); return          // down/left/right -> navigate
        case 126:
            if selectedRow <= 0 { onUpAtTop?(); return }
            super.keyDown(with: event); return          // up -> move selection
        default: break
        }
        if let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value < 0xF700,
           !CharacterSet.controlCharacters.contains(scalar) {
            onType?(chars); return
        }
        super.keyDown(with: event)
    }
}

// Themed selection highlight (accent-tinted rounded fill).
final class ThemedRowView: NSTableRowView {
    var accent: NSColor = .selectedContentBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1),
                     xRadius: 7, yRadius: 7).fill()
    }
}

// ============================================================================
// One result row — rebuilt per configure from the active theme's LayoutSpec,
// so changing theme genuinely changes the row layout, not just the colours.
// ============================================================================
final class ResultRow: NSView {
    private var stack: NSView?

    private static let longDF:  DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f }()
    private static let shortDF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yy";  return f }()
    private static let isoDF:   DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    private func label(_ font: NSFont, _ color: NSColor, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font; l.textColor = color; l.alignment = align
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func dateString(_ ts: Double, _ fmt: DateFmt) -> String {
        guard ts > 0 else { return fmt == .isoBracket ? "[ ———— ]" : "—" }
        let d = Date(timeIntervalSince1970: ts)
        switch fmt {
        case .long:       return ResultRow.longDF.string(from: d)
        case .short:      return ResultRow.shortDF.string(from: d)
        case .isoBracket: return "[\(ResultRow.isoDF.string(from: d))]"
        }
    }

    func configure(with h: Hit, theme: Theme) {
        stack?.removeFromSuperview()
        let s = theme.spec
        let nameStr = (h.path as NSString).lastPathComponent
        let dirStr  = (h.path as NSString).deletingLastPathComponent

        // --- minimal / name-only, centred -----------------------------------
        if s.nameOnly {
            let name = label(theme.font(theme.titleSize, .medium),
                             h.exists ? theme.title : theme.faint, align: .center)
            name.stringValue = nameStr
            addSubview(name); stack = name
            NSLayoutConstraint.activate([
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                name.centerXAnchor.constraint(equalTo: centerXAnchor),
            ])
            return
        }

        // --- build the labels -----------------------------------------------
        let name = label(theme.font(theme.titleSize, .semibold), h.exists ? theme.title : theme.faint)
        name.stringValue = nameStr
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let path = label(theme.font(theme.pathSize), theme.subtitle)
        path.stringValue = dirStr
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // "name" badge: accent text on an accent-tint pill, only when the name matched.
        var badgeView: NSView? = nil
        if s.showBadge && h.filename_match {
            let bl = label(theme.font(9, .semibold), theme.accent)
            bl.attributedStringValue = NSAttributedString(string: "NAME", attributes: [
                .font: theme.font(9, .semibold), .foregroundColor: theme.accent, .kern: 0.6])
            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = theme.accent.withAlphaComponent(0.16).cgColor
            pill.layer?.cornerRadius = 5
            pill.layer?.masksToBounds = true
            pill.addSubview(bl)
            NSLayoutConstraint.activate([
                bl.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                bl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                bl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
                pill.heightAnchor.constraint(equalToConstant: 15),
            ])
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            badgeView = pill
        }

        let icon = label(NSFont.systemFont(ofSize: s.iconSize), theme.title)
        icon.stringValue = ResultRow.icon(for: h.path)

        let score = label(theme.font(theme.pathSize), theme.faint, align: .right)
        score.stringValue = String(format: "%.2f", h.score)

        let date = label(theme.font(theme.pathSize), theme.faint,
                         align: s.datePos == .right ? .right : .left)
        date.stringValue = dateString(h.added, s.dateFmt)

        // The date "pill" is a container with the label centred inside it (so the
        // text sits dead-centre on BOTH axes) over a layer-drawn rounded fill.
        let dateView: NSView
        if s.datePill {
            date.textColor = theme.subtitle
            date.alignment = .center
            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = theme.faint.withAlphaComponent(0.16).cgColor
            pill.layer?.cornerRadius = 5          // less rounded (was a fat oval)
            pill.layer?.masksToBounds = true
            pill.addSubview(date)
            NSLayoutConstraint.activate([
                date.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                date.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
                date.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
                pill.heightAnchor.constraint(equalToConstant: 21),
            ])
            dateView = pill
        } else {
            dateView = date
        }

        // --- assemble the horizontal stack ----------------------------------
        let h0 = NSStackView()
        h0.orientation = .horizontal
        h0.alignment = .centerY
        h0.spacing = max(theme.rowSpacing + 4, 6)
        h0.translatesAutoresizingMaskIntoConstraints = false
        h0.detachesHiddenViews = true

        if s.datePos == .leftColumn {
            dateView.widthAnchor.constraint(equalToConstant: theme.mono ? 92 : 60).isActive = true
            h0.addArrangedSubview(dateView)
        }
        if s.showIcon {
            icon.widthAnchor.constraint(equalToConstant: s.iconSize + 8).isActive = true
            h0.addArrangedSubview(icon)
        }

        // middle: stacked (name over path) or inline (name + path one line)
        let middle: NSView
        if s.inline {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            row.addArrangedSubview(name)
            if let b = badgeView { row.addArrangedSubview(b) }
            if s.showPath { row.addArrangedSubview(path) }
            middle = row
        } else {
            let top = NSStackView()
            top.orientation = .horizontal
            top.alignment = .firstBaseline
            top.spacing = 6
            top.addArrangedSubview(name)
            if let b = badgeView { top.addArrangedSubview(b) }
            if s.showPath {
                let v = NSStackView()
                v.orientation = .vertical
                v.alignment = .leading
                v.spacing = 1
                v.addArrangedSubview(top)
                v.addArrangedSubview(path)
                middle = v
            } else {
                middle = top
            }
        }
        middle.translatesAutoresizingMaskIntoConstraints = false
        middle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        h0.addArrangedSubview(middle)

        if s.datePos == .right {
            if s.datePill { dateView.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true }
            h0.addArrangedSubview(dateView)
        }
        if s.showScore {
            score.widthAnchor.constraint(equalToConstant: 42).isActive = true
            h0.addArrangedSubview(score)
        }

        addSubview(h0); stack = h0
        let lead: CGFloat = 12, trail: CGFloat = 12
        NSLayoutConstraint.activate([
            h0.leadingAnchor.constraint(equalTo: leadingAnchor, constant: lead),
            h0.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trail),
            h0.centerYAnchor.constraint(equalTo: centerYAnchor),
            h0.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
        ])
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
// Search view controller — owns the field, type filters and results table,
// and rebuilds its whole layout when the theme changes.
// ============================================================================
final class SearchViewController: NSViewController, NSTableViewDataSource,
                                  NSTableViewDelegate, NSTextFieldDelegate,
                                  QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var theme: Theme = Themes.current()

    private var field  = NSTextField()
    private var scroll = NSScrollView()
    private var table  = ResultsTableView()
    private var status = NSTextField(labelWithString: "")
    private var filterSeg: NSSegmentedControl?

    private var hits: [Hit] = []
    private var debounce: Timer?
    private var seq = 0
    private let session = URLSession(configuration: .ephemeral)
    private var previewURL: NSURL?           // current Quick Look target

    private let kinds = [("text", "Text"), ("pdf", "PDF"), ("image", "Images"), ("video", "Video")]

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: theme.popover))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    /// Apply a new theme: rebuild the entire layout, keep the query + results.
    func apply(theme: Theme) {
        let q = field.stringValue
        self.theme = theme
        buildUI()
        field.stringValue = q
        table.reloadData()
        if !hits.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    // -- layout (theme-driven) ----------------------------------------------

    private func buildUI() {
        debounce?.invalidate(); debounce = nil   // no timer from the old UI fires post-rebuild
        view.subviews.forEach { $0.removeFromSuperview() }
        filterSeg = nil
        view.wantsLayer = true

        if theme.translucent {
            // Frosted/vibrant background (Spotlight-style): blur whatever is behind
            // the popover instead of an opaque fill.
            view.layer?.backgroundColor = NSColor.clear.cgColor
            let fx = NSVisualEffectView()
            fx.material = .menu                    // modern menu/popover surface
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.isEmphasized = true
            fx.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(fx)
            NSLayoutConstraint.activate([
                fx.topAnchor.constraint(equalTo: view.topAnchor),
                fx.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                fx.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                fx.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        } else {
            view.layer?.backgroundColor = theme.bg.cgColor
        }

        field = SearchField()
        field.placeholderString = theme.searchStyle == .prompt ? "› search by meaning…" : "Search by meaning…"
        field.font = theme.font(theme.searchSize)
        field.textColor = theme.fieldText
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = (theme.searchStyle == .centered) ? .center : .left
        styleField()

        status = NSTextField(labelWithString: "↑↓ Navigate · space Quick Look · ↵ Reveal in Finder")
        status.font = theme.font(11)
        status.textColor = theme.faint
        status.translatesAutoresizingMaskIntoConstraints = false

        // results table (fresh each rebuild)
        table = ResultsTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: theme.rowSpacing)
        table.rowHeight = theme.rowHeight
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

        scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(field)
        view.addSubview(status)
        view.addSubview(scroll)

        let m: CGFloat = 14
        var cons: [NSLayoutConstraint] = [
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: m),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m / 2),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m / 2),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -m / 2),
        ]
        if theme.searchStyle == .pill || theme.searchStyle == .centered {
            cons.append(field.heightAnchor.constraint(equalToConstant: 46))
        }

        // Filter row only when the theme wants it; otherwise the table rises up.
        if theme.showFilters {
            // Native multi-select segmented pill (independent toggles), replacing
            // the old checkbox row — the modern macOS filter control.
            let seg = NSSegmentedControl(labels: kinds.map { $0.1 },
                                         trackingMode: .selectAny,
                                         target: self, action: #selector(filtersChanged))
            seg.segmentDistribution = .fillEqually
            seg.controlSize = .regular
            seg.font = theme.font(12)
            for i in kinds.indices { seg.setSelected(true, forSegment: i) }   // all on
            seg.selectedSegmentBezelColor = theme.accent                      // tint selected
            seg.translatesAutoresizingMaskIntoConstraints = false
            filterSeg = seg

            let filterRow = NSStackView(views: [seg])
            filterRow.orientation = .horizontal
            filterRow.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(filterRow)
            cons += [
                filterRow.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
                filterRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
                status.centerYAnchor.constraint(equalTo: filterRow.centerYAnchor),
                status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -m),
                status.leadingAnchor.constraint(greaterThanOrEqualTo: filterRow.trailingAnchor, constant: 10),
                scroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 10),
            ]
        } else {
            cons += [
                status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
                status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
                status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -m),
                scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            ]
        }
        NSLayoutConstraint.activate(cons)
    }

    private func styleField() {
        field.wantsLayer = true
        switch theme.searchStyle {
        case .rounded:
            // System bezel rounds itself — let the cell paint the background.
            field.bezelStyle = .roundedBezel
            field.isBezeled = true
            field.drawsBackground = true
            field.backgroundColor = theme.fieldBg
        case .pill, .underline, .prompt, .centered:
            // Bezel-less: paint the fill on the LAYER (not the cell) and clip with
            // masksToBounds, so the cornerRadius actually rounds the corners. A cell
            // background ignores the rounded layer and renders square.
            field.isBezeled = false
            field.drawsBackground = false
            field.layer?.backgroundColor = theme.fieldBg.cgColor
            field.layer?.masksToBounds = true
            field.layer?.cornerRadius = theme.searchStyle == .pill ? 10
                : theme.searchStyle == .centered ? 12 : 6
            if theme.searchStyle == .underline || theme.searchStyle == .prompt {
                field.layer?.borderWidth = 1
                field.layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
            }
        }
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

    private func deleteBackToField() {
        if !field.stringValue.isEmpty { field.stringValue.removeLast() }
        moveCaretToEndAndSearch()
    }

    private func moveCaretToEndAndSearch() {
        view.window?.makeFirstResponder(field)
        let end = (field.stringValue as NSString).length    // UTF-16 units
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
        guard let seg = filterSeg else { return [] }
        let on = kinds.indices
            .filter { seg.isSelected(forSegment: $0) }
            .map { kinds[$0].0 }                       // "text"/"pdf"/"image"/"video"
        return on.count == kinds.count ? [] : on       // all selected == no filter
    }

    private func runSearch() {
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            seq += 1
            hits = []; table.reloadData()
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
                guard let self = self, mine == self.seq else { return }
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
    @objc private func onDoubleClick() { reveal(table.selectedRow) }

    /// Native Quick Look (QLPreviewPanel) — the macOS spacebar preview. Replaces
    /// the old `qlmanage -p` server call, which is Apple's unsupported debug tool
    /// and crashes ("qlmanage quit unexpectedly").
    private func preview(_ i: Int) {
        guard let h = hit(i) else { return }
        previewURL = NSURL(fileURLWithPath: h.path)
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func ping(_ route: String, _ path: String?) {
        guard let path = path,
              var comps = URLComponents(string: Cfg.serverURL + route) else { return }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = comps.url else { return }
        session.dataTask(with: url).resume()
    }

    // -- Quick Look panel control (responder chain) -------------------------

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL
    }

    // -- table data ---------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("themedrow")
        let rv = (tableView.makeView(withIdentifier: id, owner: self) as? ThemedRowView) ?? {
            let r = ThemedRowView(); r.identifier = id; return r
        }()
        rv.accent = theme.accent
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        // Reuse keyed by theme so a cached row from another layout is never reused.
        let id = NSUserInterfaceItemIdentifier("row-\(theme.id)")
        let v = (tableView.makeView(withIdentifier: id, owner: self) as? ResultRow) ?? {
            let r = ResultRow(); r.identifier = id; return r
        }()
        v.configure(with: hits[row], theme: theme)
        return v
    }
}

// ============================================================================
// App delegate — menu-bar item, popover, hot-key, engine lifecycle, themes.
// ============================================================================
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let searchVC = SearchViewController()
    private var server: Process?
    private var hotKeyRef: EventHotKeyRef?
    private var baseTheme = Themes.current()
    private var accentOverride: NSColor? = Themes.currentAccent()

    /// The theme actually shown: the chosen theme with the user's accent applied.
    private func effectiveTheme() -> Theme {
        guard let c = accentOverride else { return baseTheme }
        var t = baseTheme; t.accent = c; return t
    }

    private let launchKey = "turbofind.launchAtLogin"

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()                               // enables ⌘A/⌘C/⌘V/⌘X/⌘Z in the field
        startServer()
        searchVC.theme = effectiveTheme()
        buildStatusItem()
        buildPopover()
        registerHotKey()
        setupLoginItem()
    }

    /// An accessory app shows no menu bar, so the standard Edit-menu key
    /// equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z) are never wired up — the search field can't
    /// copy/paste/select-all. Install a hidden main menu with those items
    /// (nil target → routed to the first responder, i.e. the field editor).
    private func buildMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit

        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut",  action: #selector(NSText.cut(_:)),  keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    // -- launch at login ----------------------------------------------------

    /// Default ON: the first time we run, opt into starting at login so the bolt
    /// is always there after a reboot. The user can turn it off in the menu.
    private func setupLoginItem() {
        let d = UserDefaults.standard
        if d.object(forKey: launchKey) == nil { d.set(true, forKey: launchKey) }
        applyLoginItem(d.bool(forKey: launchKey))
    }

    private func applyLoginItem(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("[TurboFind] launch-at-login \(on ? "register" : "unregister") failed: \(error)")
        }
    }

    private func loginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return UserDefaults.standard.bool(forKey: launchKey)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let on = !loginItemEnabled()
        UserDefaults.standard.set(on, forKey: launchKey)
        applyLoginItem(on)
    }

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
        button.image?.isTemplate = true
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func menuBarIcon() -> NSImage {
        // Template image: the menu bar renders it monochrome from the alpha, so
        // the white mark adapts to light/dark automatically.
        let path = "\(Cfg.repoDir)/assets/logo-white.png"
        if let img = NSImage(contentsOfFile: path) {
            let h: CGFloat = 17
            img.size = NSSize(width: h * (img.size.width / max(img.size.height, 1)), height: h)
            return img
        }
        return NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "TurboFind") ?? NSImage()
    }

    // -- popover ------------------------------------------------------------

    private func buildPopover() {
        let t = effectiveTheme()
        popover.contentViewController = searchVC
        popover.contentSize = t.popover
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: t.dark ? .darkAqua : .aqua)
        popover.delegate = self
    }

    /// Re-apply the current theme+accent to the live popover.
    private func applyCurrent() {
        let t = effectiveTheme()
        popover.contentSize = t.popover
        popover.appearance = NSAppearance(named: t.dark ? .darkAqua : .aqua)
        searchVC.apply(theme: t)
        if popover.isShown { focusSearchField() }
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { showRightClickMenu(); return }
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        focusSearchField()
    }

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

    // -- right-click menu ---------------------------------------------------

    private func showRightClickMenu() {
        let menu = NSMenu()
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu()
        menu.addItem(themeItem)
        let accentItem = NSMenuItem(title: "Accent colour", action: nil, keyEquivalent: "")
        accentItem.submenu = accentMenu()
        menu.addItem(accentItem)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.state = loginItemEnabled() ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(withTitle: "Update TurboFind…", action: #selector(update), keyEquivalent: "")
        menu.addItem(withTitle: "Re-index home (~)…", action: #selector(reindex), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TurboFind", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func themeMenu() -> NSMenu {
        let m = NSMenu()
        for t in Themes.all {
            let it = NSMenuItem(title: t.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            it.representedObject = t.id
            it.state = (t.id == baseTheme.id) ? .on : .off
            it.target = self
            m.addItem(it)
        }
        return m
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let t = Themes.byId(id) else { return }
        baseTheme = t
        UserDefaults.standard.set(t.id, forKey: Themes.key)
        applyCurrent()
    }

    private func accentMenu() -> NSMenu {
        let m = NSMenu()
        let cur = UserDefaults.standard.string(forKey: Themes.accentKey)
        let def = NSMenuItem(title: "Theme default", action: #selector(pickAccent(_:)), keyEquivalent: "")
        def.representedObject = ""
        def.state = (cur == nil) ? .on : .off
        def.target = self
        m.addItem(def)
        m.addItem(.separator())
        for (name, hex) in Themes.accents {
            let s = String(hex, radix: 16)
            let it = NSMenuItem(title: name, action: #selector(pickAccent(_:)), keyEquivalent: "")
            it.representedObject = s
            it.state = (cur == s) ? .on : .off
            it.image = swatch(NSColor(hex))
            it.target = self
            m.addItem(it)
        }
        return m
    }

    @objc private func pickAccent(_ sender: NSMenuItem) {
        let s = (sender.representedObject as? String) ?? ""
        if s.isEmpty {
            UserDefaults.standard.removeObject(forKey: Themes.accentKey)
            accentOverride = nil
        } else {
            UserDefaults.standard.set(s, forKey: Themes.accentKey)
            accentOverride = NSColor(UInt32(s, radix: 16) ?? 0xa855f7)
        }
        applyCurrent()
    }

    /// A small rounded colour chip for the accent menu items.
    private func swatch(_ c: NSColor) -> NSImage {
        let sz = NSSize(width: 13, height: 13)
        let img = NSImage(size: sz)
        img.lockFocus()
        c.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: sz), xRadius: 3, yRadius: 3).fill()
        img.unlockFocus()
        return img
    }

    // -- self-update --------------------------------------------------------

    /// One-click update. `git pull`, then:
    ///  - app (Swift) changed  -> rebuild the .app and relaunch ourselves
    ///  - only Python changed   -> restart the engine in place (no rebuild)
    /// So the user never has to touch a terminal.
    @objc private func update() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (ok, out, appChanged) = self.gitPull()

            if ok && !out.contains("Already up to date") && appChanged {
                let (built, buildOut) = self.runBuild()      // recompile on this bg thread
                DispatchQueue.main.async {
                    if built {
                        self.showAlert("TurboFind", "Updated. The app will rebuild and reopen now.")
                        self.relaunchApp()                   // swap in the fresh build
                    } else {
                        self.showAlert("Update: rebuild failed",
                            "Pulled the latest, but the app failed to recompile:\n\n\(buildOut)\n\n"
                            + "You may need Xcode Command Line Tools (`xcode-select --install`), "
                            + "or run `cd ~/turbofind/menubar && ./build.sh` manually.")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                if !ok {
                    self.showAlert("Update failed", out.isEmpty ? "git pull failed." : out)
                    return
                }
                if out.contains("Already up to date") {
                    self.showAlert("TurboFind", "Already up to date.")
                    return
                }
                // Python-only change: restart the engine, no rebuild needed.
                self.showAlert("TurboFind", "Updated.\nThe engine is restarting (a few seconds).\n\n" + out)
                self.server?.terminate()
                self.server = nil
                self.startServer()
            }
        }
    }

    /// Recompile + reassemble the .app via build.sh. Returns (success, output).
    private func runBuild() -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = URL(fileURLWithPath: "\(Cfg.repoDir)/menubar")
        p.arguments = ["build.sh"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "could not run build.sh: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// Relaunch the freshly-built bundle: a detached shell waits for us to quit,
    /// then reopens the app (so the new serve.py can bind 8765 once ours frees it).
    private func relaunchApp() {
        let appPath = "\(Cfg.repoDir)/menubar/TurboFind.app"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appPath)\""]
        try? p.run()
        NSApp.terminate(nil)   // applicationWillTerminate stops our serve.py + hot-key
    }

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
        try? p.run()
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
            try p.run()
            server = p
        } catch {
            NSLog("[TurboFind] could not launch serve.py: \(error)")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        server?.terminate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
