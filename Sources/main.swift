import SwiftUI
import AppKit
import WebKit
import Combine
import ServiceManagement

// MARK: - Models (shape of claude.ai/api/organizations/{id}/usage)

struct UsageResponse: Decodable {
    let limits: [Limit]?
    let weekly_scoped_shares: [ScopedShare]?
    let cedar_ember: ResetInfo?
}

struct ResetInfo: Decodable { let grants: [ResetGrant]? }

struct ResetGrant: Decodable {
    let id: String
    let label: String?
    let resets_left: Int?
    let ends_at: String?
    let usable_now: Bool?
    let clears: [String]?
    let unavailable_reason: String?

    var displayName: String {
        let text = (id + " " + (label ?? "")).lowercased()
        if text.contains("fable") { return "Fable reset" }
        if clears?.contains("seven_day") == true { return "Full reset" }
        return label ?? "Reset"
    }
}

struct Limit: Decodable {
    let kind: String
    let percent: Double
    let severity: String?
    let resets_at: String?
    let scope: Scope?
}

struct Scope: Decodable { let model: ScopeModel? }
struct ScopeModel: Decodable { let display_name: String? }
struct ScopedShare: Decodable {
    let limit_index: Int
    let allowance_percent_of_weekly: Double?
}
struct Org: Decodable { let uuid: String }

let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// MARK: - Fetching through a hidden web view (same cookies as the sign-in window)

enum FetchError: LocalizedError {
    case badResult, loadFailed(String)
    var errorDescription: String? {
        switch self {
        case .badResult: return "Unexpected response"
        case .loadFailed(let m): return m
        }
    }
}

@MainActor
final class ClaudeFetcher: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadCont: CheckedContinuation<Void, Error>?
    private var ready = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        webView.customUserAgent = safariUA
        super.init()
        webView.navigationDelegate = self
    }

    func reset() { ready = false }

    private func ensureReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadCont = c
            webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://claude.ai/")!)
        }
        ready = true
    }

    private func finishLoad(_ error: String?) {
        if let error { loadCont?.resume(throwing: FetchError.loadFailed(error)) } else { loadCont?.resume() }
        loadCont = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad(nil) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.finishLoad(msg) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.finishLoad(msg) }
    }

    /// Returns (HTTP status, body text) for a claude.ai API path.
    func get(_ path: String) async throws -> (Int, String) {
        try await ensureReady()
        let js = """
        const r = await fetch(path, {credentials: 'include', headers: {'accept': 'application/json'},
                                     signal: AbortSignal.timeout(15000)});
        return [r.status, await r.text()];
        """
        let result = try await webView.callAsyncJavaScript(js, arguments: ["path": path], contentWorld: .page)
        guard let arr = result as? [Any], arr.count == 2 else { throw FetchError.badResult }
        let status = (arr[0] as? NSNumber)?.intValue ?? 0
        return (status, arr[1] as? String ?? "")
    }
}

// MARK: - Sign-in window

@MainActor
final class LoginWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var urlObservation: NSKeyValueObservation?
    private var onDone: (() -> Void)?
    private var finished = false

    func show(onDone: @escaping () -> Void) {
        self.onDone = onDone
        finished = false
        if let w = window {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: cfg)
        wv.customUserAgent = safariUA
        urlObservation = wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
            let url = wv.url
            Task { @MainActor [weak self] in self?.check(url) }
        }
        wv.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in to Claude"
        w.contentView = wv
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func check(_ url: URL?) {
        guard let url, url.host?.hasSuffix("claude.ai") == true else { return }
        let p = url.path
        let signedIn = ["/new", "/chat", "/recents", "/project", "/settings"].contains { p.hasPrefix($0) }
        if signedIn { finish(); window?.close() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone?()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
        urlObservation = nil
        window = nil
    }
}

// MARK: - State

@MainActor
final class UsageStore: ObservableObject {
    enum Status: Equatable { case idle, loading, needsLogin, error(String), loaded }

    @Published var limits: [Limit] = []
    @Published var allowances: [Int: Double] = [:]
    @Published var grants: [ResetGrant] = []
    @Published var status: Status = .idle
    @Published var lastUpdated: Date?

    private let fetcher = ClaudeFetcher()
    private let login = LoginWindow()
    private var orgId: String? = UserDefaults.standard.string(forKey: "orgId")

    var sessionPercent: Int? {
        limits.first { $0.kind == "session" }.map { Int($0.percent.rounded()) }
    }

    init() {
        Task { [weak self] in
            while true {
                guard let self else { return }
                if ClaudeAppWatcher.isRunning() { await self.refresh() }
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000) // every 5 minutes
            }
        }
    }

    func refreshIfStale() async {
        if let t = lastUpdated, Date().timeIntervalSince(t) < 30 { return }
        await refresh()
    }

    private var triedImport = false
    private var importedAtStartup = false

    /// Copies the Claude desktop app's login cookies into this app. Returns true if a session was found.
    private func importFromClaudeApp() async -> Bool {
        let cookies = await Task.detached { ClaudeAppCookies.cookies() }.value
        guard cookies.contains(where: { $0.name.hasPrefix("sessionKey") }) else { return false }
        let jar = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies { await jar.setCookie(c) }
        fetcher.reset()
        orgId = nil
        return true
    }

    func refresh() async {
        if status == .loading { return }
        if !importedAtStartup {
            importedAtStartup = true
            _ = await importFromClaudeApp()
        }
        await refreshOnce()
        if status != .loaded && !triedImport {
            triedImport = true
            if await importFromClaudeApp() { await refreshOnce() }
        }
        if status == .loaded { triedImport = false }
    }

    private func refreshOnce() async {
        if status == .loading { return }
        status = .loading
        do {
            if let id = orgId, try await loadUsage(org: id) { return }
            // Discover the organization (first one whose usage endpoint answers).
            let (s, body) = try await fetcher.get("/api/organizations")
            if s == 401 || s == 403 { status = .needsLogin; return }
            guard s == 200 else { status = .error("Couldn't list organizations (HTTP \(s))"); return }
            let orgs = try JSONDecoder().decode([Org].self, from: Data(body.utf8))
            for org in orgs {
                if try await loadUsage(org: org.uuid) {
                    orgId = org.uuid
                    UserDefaults.standard.set(org.uuid, forKey: "orgId")
                    return
                }
                if status == .needsLogin { return }
            }
            status = .error("No usage data found")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// true = loaded successfully
    private func loadUsage(org: String) async throws -> Bool {
        let (s, body) = try await fetcher.get("/api/organizations/\(org)/usage?cedar_ember=1&skip_spend=1")
        if s == 401 { status = .needsLogin; return false }
        guard s == 200 else { return false }
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(body.utf8))
        guard let l = u.limits, !l.isEmpty else { return false }
        limits = l
        allowances = (u.weekly_scoped_shares ?? []).reduce(into: [:]) { d, share in
            if let a = share.allowance_percent_of_weekly { d[share.limit_index] = a }
        }
        grants = (u.cedar_ember?.grants ?? []).filter { ($0.resets_left ?? 0) > 0 }
        lastUpdated = Date()
        status = .loaded
        return true
    }

    func promptForSessionKey() {
        let alert = NSAlert()
        alert.messageText = "Paste your claude.ai session key"
        alert.informativeText = "From Chrome: claude.ai → DevTools → Application → Cookies → https://claude.ai → sessionKey. It is stored only on this Mac."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), clip.hasPrefix("sk-ant-") {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task { await useSessionKey(key) }
    }

    func useSessionKey(_ key: String) async {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "sessionKey", .value: key, .domain: ".claude.ai", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(30 * 24 * 3600)
        ]
        if let cookie = HTTPCookie(properties: props) {
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        }
        fetcher.reset()
        orgId = nil
        status = .idle
        await refresh()
    }

    func signIn() {
        login.show { [weak self] in
            guard let self else { return }
            self.fetcher.reset()
            self.status = .idle
            Task { await self.refresh() }
        }
    }
}

// MARK: - Show the icon only while the Claude app is running

@MainActor
final class ClaudeAppWatcher: ObservableObject {
    @Published var isClaudeRunning: Bool
    private var tokens: [NSObjectProtocol] = []

    private var timer: Timer?

    static func isRunning() -> Bool {
        let desktop = NSWorkspace.shared.runningApplications.contains { app in
            if app.bundleIdentifier == "com.anthropic.claudefordesktop" { return true }
            return app.localizedName == "Claude" && app.activationPolicy == .regular
        }
        return desktop || pgrep(["-x", "claude"]) || pgrep(["-f", "@anthropic-ai/claude-code"])
    }

    private static func pgrep(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private func update() {
        let r = Self.isRunning()
        if r != isClaudeRunning { isClaudeRunning = r }
    }

    init() {
        isClaudeRunning = Self.isRunning()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.update() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
    }
}

// MARK: - Formatting

func parseDate(_ raw: String?) -> Date? {
    guard var s = raw else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        let trimmed = String(s[r].prefix(4))
        s.replaceSubrange(r, with: trimmed)
        if let d = f.date(from: s) { return d }
    }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func resetText(_ raw: String?) -> String? {
    guard let d = parseDate(raw) else { return nil }
    let f = DateFormatter()
    let soon = d.timeIntervalSinceNow < 6 * 24 * 3600
    f.setLocalizedDateFormatFromTemplate(soon ? "EEEE j:mm" : "MMM d j:mm")
    return "Resets \(f.string(from: d))"
}

func expiryText(_ raw: String?) -> String? {
    guard let d = parseDate(raw) else { return nil }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMM d j:mm")
    return "Expires \(f.string(from: d))"
}

func title(for limit: Limit) -> String {
    switch limit.kind {
    case "session": return "Current session"
    case "weekly_all": return "This week"
    default: return limit.scope?.model?.display_name ?? limit.kind
    }
}

func color(for severity: String?) -> Color {
    switch severity {
    case nil, "normal": return .accentColor
    case "critical": return .red
    default: return .orange
    }
}

// MARK: - UI

struct LimitRow: View {
    let limit: Limit
    let allowance: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title(for: limit)).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int(limit.percent.rounded()))% used")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(max(limit.percent, 0), 100), total: 100)
                .tint(color(for: limit.severity))
            if let a = allowance {
                Text("Up to \(Int(a))% of your weekly limit")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let r = resetText(limit.resets_at) {
                Text(r).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ResetRow: View {
    let grant: ResetGrant

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(grant.displayName).font(.system(size: 13, weight: .medium))
                if let e = expiryText(grant.ends_at) {
                    Text(e).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if grant.usable_now == false, let why = grant.unavailable_reason {
                    Text("Not usable now: \(why)").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let n = grant.resets_left, n > 1 {
                Text("×\(n)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsagePopover: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude usage").font(.headline)
                Spacer()
                if store.status == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.borderless).help("Refresh")
                }
            }

            switch store.status {
            case .needsLogin:
                Text("Couldn't pick up your login from the Claude app. Make sure you're signed in there, then refresh.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Paste session key from Chrome") { store.promptForSessionKey() }
                Button("Or sign in here") { store.signIn() }.buttonStyle(.link).font(.system(size: 11))
            case .error(let msg) where store.limits.isEmpty:
                Text(msg).font(.system(size: 12)).foregroundStyle(.red)
                Button("Paste session key from Chrome") { store.promptForSessionKey() }
            default:
                ForEach(Array(store.limits.enumerated()), id: \.offset) { i, l in
                    LimitRow(limit: l, allowance: store.allowances[i])
                }
                if !store.grants.isEmpty {
                    Divider()
                    HStack {
                        Text("Limit resets").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(store.grants.reduce(0) { $0 + ($1.resets_left ?? 0) }) available")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(store.grants, id: \.id) { ResetRow(grant: $0) }
                }
                if case .error(let msg) = store.status {
                    Text(msg).font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            Divider()

            HStack {
                Button("Open Usage page") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                Spacer()
                if let t = store.lastUpdated {
                    Text(t, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Menu bar item (AppKit)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let watcher = ClaudeAppWatcher()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Minimal Edit menu so Cmd+C / Cmd+V / Cmd+A work in text fields.
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                              accessibilityDescription: "Claude usage")
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(togglePopover(_:))
        }

        let host = NSHostingController(rootView: UsagePopover().environmentObject(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        store.$limits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] limits in
                func pct(_ kind: String) -> String? {
                    limits.first { $0.kind == kind }.map { "\(Int($0.percent.rounded()))%" }
                }
                var parts: [String] = []
                if let s = pct("session") { parts.append("5h \(s)") }
                if let w = pct("weekly_all") { parts.append("W \(w)") }
                self?.statusItem.button?.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
            }
            .store(in: &cancellables)

        watcher.$isClaudeRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                self.statusItem.isVisible = running
                if running { Task { await self.store.refreshIfStale() } }
                else { self.popover.performClose(nil) }
            }
            .store(in: &cancellables)
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let b = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.refreshIfStale() }
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}
