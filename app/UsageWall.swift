// Usage Wall — shows the usage-wall page on the display you pick, from the menu bar.
//
// One app does everything: it starts the bundled local server (Resources/server/server.py, stdlib Python) as a
// child process, shows the page (Resources/web) in a WKWebView, and lets you choose where it goes:
//   - a dedicated (non-main) display: a borderless panel that fills it, joins every Space, sits above that display's
//     menu bar and never takes focus (native full screen would live in its own Space and vanish on Space switches)
//   - the main display, or "Floating Window": an ordinary resizable window (3:2), optionally kept on top
//   - Automatic: the smallest non-main display if there is one, else the window
// The choice is saved in ~/Library/Application Support/UsageWall/config.json and follows hot-plug: an unplugged
// display hides the panel until it comes back.
//
// Command line (used by install.sh and bin/usage-wall):
//   UsageWall --list-displays | --set-display <name|auto|window> | --signin on|off | --config | --reload
//             --install-agent | --uninstall-agent | --help
import AppKit
import WebKit

// MARK: - names and paths (install.sh / uninstall.sh use the same label)

let agentLabel = "io.github.porgeeratad.usagewall"
let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/UsageWall")
let configURL = supportDir.appendingPathComponent("config.json")
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let logPath = home.appendingPathComponent("Library/Logs/UsageWall.log").path
let reloadNote = Notification.Name("\(agentLabel).reload")
let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Usage Wall"

let stamp: DateFormatter = {  // POSIX + Gregorian: the system calendar may be Buddhist, Japanese, ...
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()
func log(_ s: String) { print("\(stamp.string(from: Date())) usage-wall: \(s)"); fflush(stdout) }

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit(); return p.terminationStatus
}

// MARK: - config

struct Config: Codable {
    var display = "window"      // "window" | "auto" | a display's name as macOS shows it (shown in menus/CLI)
    var displayUUID = ""        // the chosen display's UUID: the real key (names repeat and get localized)
    var port = 8765
    var pollMinutes = 10
    var keepOnTop = false       // window mode only
    var useSignIn = false       // also read usage with Claude Code's sign-in (undocumented endpoint) - opt-in

    init() {}
    init(from d: Decoder) throws {  // tolerate missing keys: an older or hand-edited file still loads
        let c = try d.container(keyedBy: CodingKeys.self)
        display = try c.decodeIfPresent(String.self, forKey: .display) ?? display
        displayUUID = try c.decodeIfPresent(String.self, forKey: .displayUUID) ?? displayUUID
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? port
        pollMinutes = try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? pollMinutes
        keepOnTop = try c.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? keepOnTop
        useSignIn = try c.decodeIfPresent(Bool.self, forKey: .useSignIn) ?? useSignIn
    }
}

func loadConfig() -> Config {
    guard let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
    return c
}
func saveConfig(_ c: Config) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? e.encode(c) { try? d.write(to: configURL, options: .atomic) }
}

// MARK: - displays

/// NSScreen.screens.first is the display with the menu bar ("main" here, whatever NSScreen.main says).
func mainScreen() -> NSScreen? { NSScreen.screens.first }
func isMain(_ s: NSScreen) -> Bool { s == mainScreen() }
func sizeText(_ s: NSScreen) -> String { "\(Int(s.frame.width))×\(Int(s.frame.height))" }

/// Stable across screen-parameter changes (NSScreen objects are recreated; the display number is not).
func displayID(_ s: NSScreen) -> UInt32 { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
/// Stable across reboots and system language: what the config stores.
func displayUUID(_ s: NSScreen) -> String {
    guard let u = CGDisplayCreateUUIDFromDisplayID(displayID(s))?.takeRetainedValue() else { return "" }
    return (CFUUIDCreateString(nil, u) as String?) ?? ""
}
func chosenScreen(_ c: Config) -> NSScreen? {
    if !c.displayUUID.isEmpty, let s = NSScreen.screens.first(where: { displayUUID($0) == c.displayUUID }) { return s }
    return NSScreen.screens.first(where: { $0.localizedName == c.display })
}
func choose(_ c: inout Config, _ v: String) {          // v = auto | window | a display name
    c.display = v
    c.displayUUID = ["auto", "window"].contains(v) ? "" : (NSScreen.screens.first(where: { $0.localizedName == v }).map(displayUUID) ?? "")
}
func isChosen(_ c: Config, _ s: NSScreen) -> Bool {
    if !c.displayUUID.isEmpty { return displayUUID(s) == c.displayUUID }
    return c.display == s.localizedName
}

enum Placement: Equatable {
    case panel(NSScreen)        // fills a dedicated display
    case window(NSScreen)       // a normal window, first shown on this display
    case missing(String)        // the chosen display is not connected

    static func == (a: Placement, b: Placement) -> Bool {
        switch (a, b) {
        case (.panel(let x), .panel(let y)), (.window(let x), .window(let y)): return displayID(x) == displayID(y)
        case (.missing(let x), .missing(let y)): return x == y
        default: return false
        }
    }

    static func resolve(_ c: Config) -> Placement {
        let screens = NSScreen.screens
        guard let main = mainScreen() else { return .missing(c.display) }
        switch c.display {
        case "window":
            return .window(main)
        case "auto":
            let others = screens.dropFirst()
            if let small = others.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return .panel(small)
            }
            return .window(main)
        default:
            guard let s = chosenScreen(c) else { return .missing(c.display) }
            return isMain(s) ? .window(s) : .panel(s)   // never cover the display that has the menu bar
        }
    }
}

// MARK: - login agent

func agentPlist(_ exe: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(agentLabel)</string>
      <key>ProgramArguments</key><array><string>\(exe)</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
      <key>ThrottleInterval</key><integer>10</integer>
      <key>ProcessType</key><string>Interactive</string>
      <key>StandardOutPath</key><string>\(logPath)</string>
      <key>StandardErrorPath</key><string>\(logPath)</string>
    </dict>
    </plist>
    """
}
var loginEnabled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

/// startNow: bootstrap the agent too (install.sh); from the running app only the file is written, so launchd does
/// not start a second copy - the agent takes over at the next login.
func enableLogin(startNow: Bool) -> Bool {
    guard let exe = Bundle.main.executablePath else { return false }
    try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard (try? agentPlist(exe).write(to: agentURL, atomically: true, encoding: .utf8)) != nil else { return false }
    let uid = getuid()
    run("/bin/launchctl", ["enable", "gui/\(uid)/\(agentLabel)"])
    if startNow {
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
        return run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentURL.path]) == 0
    }
    return true
}

/// stopNow: also unload it (uninstall.sh - that ends a running copy started by launchd). From the running app the
/// file goes and the job is disabled, so it does not come back at login; this copy keeps running until Quit.
func disableLogin(stopNow: Bool) {
    let uid = getuid()
    if stopNow { run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"]) }
    run("/bin/launchctl", ["disable", "gui/\(uid)/\(agentLabel)"])
    try? FileManager.default.removeItem(at: agentURL)
}

// MARK: - command line

func cli(_ args: [String]) -> Int32 {
    _ = NSApplication.shared   // a window-server connection, so NSScreen works
    switch args.first ?? "" {
    case "--list-displays":
        for s in NSScreen.screens {
            print("\(s.localizedName)\t\(sizeText(s))\t\(isMain(s) ? "main (window)" : "dedicated (full screen)")")
        }
        return 0
    case "--set-display":
        guard args.count >= 2, !args[1].isEmpty else { fputs("usage: --set-display <name|auto|window>\n", stderr); return 2 }
        var c = loadConfig(); choose(&c, args[1]); saveConfig(c)
        if args[1] != "auto", args[1] != "window", !NSScreen.screens.contains(where: { $0.localizedName == args[1] }) {
            fputs("note: no display named \"\(args[1])\" is connected now; it will be used when it is\n", stderr)
        }
        DistributedNotificationCenter.default().postNotificationName(reloadNote, object: nil, userInfo: nil, deliverImmediately: true)
        print("display = \(args[1])"); return 0
    case "--signin":
        guard args.count >= 2, ["on", "off"].contains(args[1]) else { fputs("usage: --signin on|off\n", stderr); return 2 }
        var c = loadConfig(); c.useSignIn = args[1] == "on"; saveConfig(c)
        DistributedNotificationCenter.default().postNotificationName(reloadNote, object: nil, userInfo: nil, deliverImmediately: true)
        print("sign-in mode \(args[1])"); return 0
    case "--config":
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: (try? e.encode(loadConfig())) ?? Data(), encoding: .utf8) ?? "{}")
        print("file: \(configURL.path)"); return 0
    case "--reload":
        DistributedNotificationCenter.default().postNotificationName(reloadNote, object: nil, userInfo: nil, deliverImmediately: true)
        return 0
    case "--install-agent":
        if enableLogin(startNow: true) { print("login agent \(agentLabel) loaded"); return 0 }
        fputs("could not write or load \(agentURL.path)\n", stderr); return 1
    case "--uninstall-agent":
        disableLogin(stopNow: true); print("login agent \(agentLabel) removed"); return 0
    default:
        print("""
        \(appName) — usage:
          UsageWall                      run (menu bar app)
          UsageWall --list-displays      name, size and how it would be used
          UsageWall --set-display NAME   NAME | auto | window (saved; a running copy moves at once)
          UsageWall --signin on|off      also read usage with Claude Code's sign-in (unofficial endpoint)
          UsageWall --config             print the settings file
          UsageWall --reload             reload the page in the running copy
          UsageWall --install-agent      start at login (and now)
          UsageWall --uninstall-agent    stop and do not start at login
        """)
        return args.first == "--help" ? 0 : 2
    }
}

// MARK: - the bundled server

/// /usr/bin/python3 is a shim that runs the Command Line Tools' Python as a child, so terminating the shim would
/// leave the real server running (still holding the port). Run the real interpreter: ask the shim once.
let python: String = {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-c", "import sys; print(sys.executable)"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return "/usr/bin/python3"
}()

final class Server {
    var proc: Process?
    var feed: Pipe?            // the server exits when this closes (USAGE_WALL_PARENT_WATCH)
    var stopping = false
    let port: Int, pollMinutes: Int, signIn: Bool

    init(_ c: Config) { port = c.port; pollMinutes = c.pollMinutes; signIn = c.useSignIn }

    var health: URL { URL(string: "http://127.0.0.1:\(port)/api/health")! }

    var portTaken = false      // the server exited 75: another program has the port; do not loop

    /// Start ours unless a usage-wall server already answers on the port (a dev copy run by hand).
    func ensure() {
        if portTaken || stopping { return }
        var req = URLRequest(url: health); req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200, let d = data,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["app"] as? String == "usage-wall" { return }
            DispatchQueue.main.async { self.start() }
        }.resume()
    }

    func start() {
        if stopping { return }    // being replaced (settings changed): the new Server starts once this one is gone
        if let p = proc, p.isRunning { return }
        guard let res = Bundle.main.resourceURL else { return }
        let script = res.appendingPathComponent("server/server.py").path
        guard FileManager.default.fileExists(atPath: script) else { log("server.py missing from the app bundle"); return }
        let p = Process(), feed = Pipe()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["USAGE_WALL_PORT"] = String(port)
        env["USAGE_WALL_WEB"] = res.appendingPathComponent("web").path
        env["USAGE_WALL_POLL_SEC"] = String(max(1, pollMinutes) * 60)
        env["USAGE_WALL_PARENT_WATCH"] = "1"
        env["USAGE_WALL_SIGNIN"] = signIn ? "1" : "0"
        env["USAGE_WALL_VERSION"] = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":" + home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        p.standardInput = feed
        p.terminationHandler = { [weak self] t in
            guard let self = self, !self.stopping else { return }
            if t.terminationStatus == 75 {
                self.portTaken = true
                log("port \(self.port) is used by another program - pick another \"port\" in \(configURL.path), then Reload")
                return
            }
            log("server exited (\(t.terminationStatus)) - restarting in 5 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.start() }
        }
        do { try p.run(); proc = p; self.feed = feed; log("server started on 127.0.0.1:\(port) (pid \(p.processIdentifier))") }
        catch { log("could not start the server: \(error.localizedDescription) - are the Xcode Command Line Tools installed?") }
    }

    func stop() { stopping = true; feed?.fileHandleForWriting.closeFile(); proc?.terminate() }
}

// MARK: - windows

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSMenuDelegate, NSWindowDelegate {
    var config = loadConfig()
    var server: Server!
    var web: WKWebView!
    var panel: Panel!
    var window: NSWindow!
    var placement: Placement?
    var status: NSStatusItem!
    var summary = "Starting…"
    var activity: NSObjectProtocol?
    var retryDelay = 5.0
    var windowClosed = false   // the user closed the window: reloads and wake do not bring it back

    var base: String { "http://127.0.0.1:\(config.port)/" }

    func applicationDidFinishLaunching(_ n: Notification) {
        // keep the page's timers at full rate (App Nap); display/system sleep still allowed
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "usage wall display")
        server = Server(config)
        server.ensure()

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: WKWebViewConfiguration())
        web.navigationDelegate = self

        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)   // above that display's menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.hasShadow = false
        panel.backgroundColor = .black

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = appName
        window.contentAspectRatio = NSSize(width: 3, height: 2)
        window.minSize = NSSize(width: 480, height: 352)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.delegate = self
        window.setFrameAutosaveName("UsageWallWindow")

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: appName) {
            img.isTemplate = true; status.button?.image = img; status.button?.imagePosition = .imageLeading
        } else { status.button?.title = "UW" }
        let menu = NSMenu(); menu.delegate = self; status.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: reloadNote, object: nil)
        // backstop for a missed screen-change notification (hot-plug can settle after it fires)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.place(force: false) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshSummary() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refreshSummary() }

        place(force: true)
    }

    func applicationWillTerminate(_ n: Notification) { server.stop() }

    // MARK: placement

    @objc func screensChanged() { place(force: false) }

    func place(force: Bool) {
        let p = Placement.resolve(config)
        if !force, p == placement {
            if case .panel(let s) = p, panel.frame != s.frame { panel.setFrame(s.frame, display: true) }
            return
        }
        let was = placement; placement = p
        switch p {
        case .panel(let s):
            window.orderOut(nil); window.contentView = nil
            panel.contentView = web
            panel.setFrame(s.frame, display: true)
            panel.orderFrontRegardless()
            log("full screen on \"\(s.localizedName)\" \(sizeText(s))")
        case .window(let s):
            panel.orderOut(nil); panel.contentView = nil
            window.contentView = web
            window.level = config.keepOnTop ? .floating : .normal
            if case .window = was {} else {
                if !window.setFrameUsingName("UsageWallWindow") || !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                    let v = s.visibleFrame
                    window.setFrame(NSRect(x: v.midX - 480, y: v.midY - 320, width: 960, height: 640 + 28), display: true)
                }
            }
            if !windowClosed { window.makeKeyAndOrderFront(nil) }
            log("window on \"\(s.localizedName)\"\(windowClosed ? " (closed by the user)" : "")")
        case .missing(let name):
            panel.orderOut(nil); window.orderOut(nil)
            log("display \"\(name)\" not connected - hidden until it is")
        }
        if force || kiosk(was) != kiosk(p) { load() }
    }

    func kiosk(_ p: Placement?) -> Bool { if case .panel = p { return true }; return false }

    func load() {
        let url = URL(string: base + (kiosk(placement) ? "?kiosk=1" : ""))!
        web.load(URLRequest(url: url))
    }

    @objc func reload() {
        let old = config; config = loadConfig()
        log("reload")
        if old.port != config.port || old.pollMinutes != config.pollMinutes || old.useSignIn != config.useSignIn {
            restartServer()
        } else { server.ensure() }
        place(force: true)
    }
    @objc func wake() { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.reload() } }

    // opening the app while it runs = reload, and show the window if that is the mode
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { windowClosed = false; reload(); return false }

    // closing the window keeps the app in the menu bar
    func windowShouldClose(_ w: NSWindow) -> Bool { windowClosed = true; w.orderOut(nil); return false }

    // MARK: menu bar

    func refreshSummary() {
        guard let url = URL(string: base + "api/state") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var text = self.config.useSignIn ? "No usage data yet" : "Waiting for Claude Code's status line"
            var short = ""
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let wk = (j["seven_day"] as? [String: Any])?["percent"] as? Double
                let fh = (j["five_hour"] as? [String: Any])?["percent"] as? Double
                if let wk = wk { short = " \(Int(wk.rounded()))%"; text = "Weekly \(Int(wk.rounded()))%" }
                if let fh = fh { text += (wk == nil ? "" : " · ") + "5-hour \(Int(fh.rounded()))%" }
                if let r = (j["seven_day"] as? [String: Any])?["resets_at"] as? Double {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE HH:mm"
                    text += " · resets \(f.string(from: Date(timeIntervalSince1970: r)))"
                }
                if let e = j["oauth_error"] as? String, wk == nil { text = "Usage error: \(e)" }
            } else { text = self.server.portTaken ? "Port \(self.config.port) is used by another program (see config.json)" : "Server not answering" }
            DispatchQueue.main.async { self.summary = text; self.status.button?.title = short }
        }.resume()
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let head = NSMenuItem(title: summary, action: nil, keyEquivalent: ""); head.isEnabled = false; m.addItem(head)
        m.addItem(.separator())

        let on = NSMenuItem(title: "Show On", action: nil, keyEquivalent: ""); let sub = NSMenu()
        let auto = item("Automatic", #selector(pickDisplay(_:)), "auto"); auto.state = config.display == "auto" ? .on : .off
        sub.addItem(auto); sub.addItem(.separator())
        for s in NSScreen.screens {
            let i = item("\(s.localizedName) — \(sizeText(s)) \(isMain(s) ? "(window)" : "(full screen)")", #selector(pickDisplay(_:)), s.localizedName)
            i.state = !["auto", "window"].contains(config.display) && isChosen(config, s) ? .on : .off; sub.addItem(i)
        }
        if !["auto", "window"].contains(config.display), chosenScreen(config) == nil {
            let i = item("\(config.display) — not connected", nil, nil); i.state = .on; i.isEnabled = false; sub.addItem(i)
        }
        sub.addItem(.separator())
        let win = item("Floating Window", #selector(pickDisplay(_:)), "window"); win.state = config.display == "window" ? .on : .off
        sub.addItem(win)
        on.submenu = sub; m.addItem(on)

        if case .window = placement {
            let top = item("Keep Window on Top", #selector(toggleTop), nil); top.state = config.keepOnTop ? .on : .off; m.addItem(top)
            m.addItem(item("Show Window", #selector(showWindow), nil))
        }
        m.addItem(.separator())
        m.addItem(item("Reload", #selector(reload), nil, key: "r"))
        m.addItem(item("Open in Browser", #selector(openBrowser), nil))
        if config.useSignIn { m.addItem(item("Refresh Usage Now", #selector(refreshNow), nil)) }
        let si = item("Read Usage with Claude Sign-in…", #selector(toggleSignIn), nil); si.state = config.useSignIn ? .on : .off
        m.addItem(si)
        m.addItem(.separator())
        let login = item("Start at Login", #selector(toggleLogin), nil); login.state = loginEnabled ? .on : .off; m.addItem(login)
        m.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), nil, key: "q"))
    }

    func item(_ title: String, _ action: Selector?, _ rep: String?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        i.representedObject = rep; return i
    }

    @objc func pickDisplay(_ i: NSMenuItem) {
        guard let v = i.representedObject as? String else { return }
        choose(&config, v); saveConfig(config); windowClosed = false; place(force: true)
    }
    @objc func toggleTop() { config.keepOnTop.toggle(); saveConfig(config); window.level = config.keepOnTop ? .floating : .normal }
    @objc func showWindow() { windowClosed = false; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func openBrowser() { if let u = URL(string: base) { NSWorkspace.shared.open(u) } }
    @objc func refreshNow() {
        var r = URLRequest(url: URL(string: base + "api/refresh")!); r.httpMethod = "POST"
        r.setValue("1", forHTTPHeaderField: "X-Usage-Wall")
        URLSession.shared.dataTask(with: r) { _, _, _ in DispatchQueue.main.async { self.refreshSummary(); self.web.reload() } }.resume()
    }
    @objc func toggleSignIn() {
        if !config.useSignIn {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Read usage with your Claude sign-in?"
            a.informativeText = """
            By default the wall gets its numbers from Claude Code's status line, so it only updates while you use \
            Claude Code.

            With this on, it also reads your Claude Code sign-in token from the Keychain and asks Anthropic's usage \
            endpoint every \(config.pollMinutes) minutes, so it stays current. That endpoint is undocumented and \
            this is not an official Anthropic feature: it may stop working, and you use it with your own account at \
            your own risk. The token only goes to api.anthropic.com and is never stored or logged.
            """
            a.addButton(withTitle: "Turn On"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        config.useSignIn.toggle(); saveConfig(config)
        restartServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refreshSummary(); self.web.reload() }
    }

    /// New settings for the server: wait for the old one to exit (it still answers /api/health until then), then start.
    func restartServer() {
        let old = server!; old.stop()
        DispatchQueue.global().async {
            old.proc?.waitUntilExit()
            DispatchQueue.main.async { self.server = Server(self.config); self.server.ensure() }   // a dev copy may hold the port
        }
    }
    @objc func toggleLogin() { if loginEnabled { disableLogin(stopNow: false) } else { _ = enableLogin(startNow: false) } }

    // MARK: web view

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { retryDelay = 5 }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { retry(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { retry(e) }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("web content process died - reloading"); load() }

    func retry(_ e: Error) {
        log("load failed: \(e.localizedDescription) - retry in \(Int(retryDelay)) s")
        server.ensure()
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { self.load() }
        retryDelay = min(retryDelay * 2, 60)
    }
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
if let first = argv.first, first.hasPrefix("--") { exit(cli(argv)) }

// one copy: a second launch (login agent vs. Finder) asks the running one to reload, then exits 0 (the agent has
// KeepAlive SuccessfulExit=false, so a clean exit is not respawned). A lock file, not the process list: the CLI
// runs this same binary (install.sh's --install-agent is still alive while launchd starts the app).
try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
let lockFD = open(supportDir.appendingPathComponent(".running.lock").path, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(reloadNote, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
