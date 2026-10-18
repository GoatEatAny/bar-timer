// BarTimer: a work timer that shows the time left as a bar in the macOS menu bar.
//
// Built on NSStatusItem rather than SwiftUI's MenuBarExtra, because MenuBarExtra may draw
// its label as a single-color template image, which would lose the bar's colors.
import AppKit
import UserNotifications

let presetMinutes = [5, 15, 30, 45, 60]
// How long the bar blinks after time is up. After that it stays red without redrawing.
let blinkDuration: TimeInterval = 60
// The bar is split into this many cells; each stands for 1/10 of the time set.
let segmentCount = 10

enum Phase {
    case idle
    case running(end: Date)
    case paused(remaining: TimeInterval)
    case finished(at: Date)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var phase = Phase.idle
    var total: TimeInterval = 0
    var blinkOn = true
    // Kept so the first line keeps counting down while the menu is open.
    var header: NSMenuItem?
    // Once notifications are denied the app cannot ask again, so the menu offers a way to the settings.
    var notificationStatus = UNAuthorizationStatus.notDetermined

    var showDigits: Bool {
        get { UserDefaults.standard.object(forKey: "showDigits") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showDigits") }
    }

    // Counted back from the end time, so time keeps passing while the Mac sleeps.
    var remaining: TimeInterval {
        switch phase {
        case .idle, .finished: return 0
        case .running(let end): return max(0, end.timeIntervalSinceNow)
        case .paused(let r): return r
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        // Lets macOS remember where the user ⌘-dragged the item, across launches and rebuilds.
        item.autosaveName = "BarTimer"
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        installEditMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Without .customDismissAction the app is not told when the notification is closed.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "finished", actions: [], intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ])
        center.requestAuthorization(options: [.alert]) { _, error in
            if let error { NSLog("BarTimer: notification authorization failed: %@", error as NSError) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshNotificationStatus() } }
        }

        // Scheduled in .common mode so the bar keeps moving while the menu or a dialog is open.
        let ticker = Timer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        ticker.tolerance = 0.1
        RunLoop.main.add(ticker, forMode: .common)
        render()
    }

    // A menu bar app has no Edit menu, so ⌘V and friends do nothing in text fields.
    // An invisible main menu passes those shortcuts through.
    func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // Redraws only while running or showing that time is up; idle and paused do nothing.
    @objc func tick() {
        switch phase {
        case .running:
            if remaining <= 0 { finish() }
            render()
        case .finished(let at):
            blinkOn = Date().timeIntervalSince(at) > blinkDuration ? true : !blinkOn
            render()
        case .idle, .paused:
            break
        }
    }

    // Changing the setting in System Settings sends no event, so it is re-read whenever the menu opens.
    // The answer arrives asynchronously and shows the next time the menu opens.
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.notificationStatus = status } }
        }
    }

    @objc func openNotificationSettings(_ sender: NSMenuItem) {
        let id = Bundle.main.bundleIdentifier ?? ""
        // macOS 13 and later can open this app's own page; macOS 12 only the list of apps.
        let address = if #available(macOS 13, *) {
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
        } else {
            "x-apple.systempreferences:com.apple.preference.notifications"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    // MARK: - State changes

    func begin(minutes: Int) {
        total = TimeInterval(minutes * 60)
        phase = .running(end: Date().addingTimeInterval(total))
        render()
    }

    func finish() {
        phase = .finished(at: Date())
        blinkOn = true
        NSSound(named: "Glass")?.play()

        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = "Your \(Int(total / 60))-minute timer has finished."
        content.categoryIdentifier = "finished"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Clears the time-up display. Called when the menu opens or closes, and when the
    // notification is clicked or closed.
    func dismissFinished() {
        guard case .finished = phase else { return }
        phase = .idle
        render()
    }

    @objc func startPreset(_ sender: NSMenuItem) { begin(minutes: sender.tag) }

    // Opening a modal from inside the menu action leaves the status item looking pressed, so wait a beat.
    @objc func startCustom(_ sender: NSMenuItem) {
        perform(#selector(askMinutes), with: nil, afterDelay: 0)
    }

    // NSAlert left-aligns its icon and text from macOS 26 on, with no option to center them,
    // so this builds a small panel with everything centered.
    @objc func askMinutes() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "How many minutes?")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(labelWithString: "Enter 1 to 600")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let field = NSTextField()
        field.placeholderString = "minutes"
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(endAsk))
        cancel.keyEquivalent = "\u{1b}"
        let start = NSButton(title: "Start", target: self, action: #selector(endAsk))
        start.keyEquivalent = "\r"
        start.tag = 1
        let buttons = NSStackView(views: [cancel, start])
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, title, note, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(16, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A stack view used directly as a window's contentView ignores edgeInsets, so pad it from outside.
        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            field.widthAnchor.constraint(equalToConstant: 120),
            buttons.widthAnchor.constraint(equalToConstant: 220),
        ])

        panel.setContentSize(content.fittingSize)
        panel.initialFirstResponder = field
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard response == .OK else { return }

        // Input methods for CJK languages may type full-width digits ("２５"), so convert to half-width first.
        let text = (field.stringValue.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(text), (1...600).contains(minutes) else {
            NSSound.beep()
            return
        }
        begin(minutes: minutes)
    }

    @objc func endAsk(_ sender: NSButton) {
        NSApp.stopModal(withCode: sender.tag == 1 ? .OK : .cancel)
    }

    // An open menu's items can be stale, so check the state at the moment the item is chosen.
    @objc func pause(_ sender: NSMenuItem) {
        guard case .running = phase, remaining > 0 else { return }
        phase = .paused(remaining: remaining)
        render()
    }

    @objc func resume(_ sender: NSMenuItem) {
        guard case .paused(let r) = phase else { return }
        phase = .running(end: Date().addingTimeInterval(r))
        render()
    }

    @objc func stop(_ sender: NSMenuItem) {
        phase = .idle
        render()
    }

    @objc func toggleDigits(_ sender: NSMenuItem) {
        showDigits.toggle()
        render()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        dismissFinished()
        refreshNotificationStatus()
        menu.removeAllItems()

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        self.header = header
        menu.addItem(.separator())

        switch phase {
        case .running:
            add(to: menu, "Pause", #selector(pause), key: "p")
            add(to: menu, "Stop", #selector(stop))
            menu.addItem(.separator())
        case .paused:
            add(to: menu, "Resume", #selector(resume), key: "p")
            add(to: menu, "Stop", #selector(stop))
            menu.addItem(.separator())
        default:
            break
        }

        for (i, minutes) in presetMinutes.enumerated() {
            add(to: menu, "\(minutes) min", #selector(startPreset), key: "\(i + 1)").tag = minutes
        }
        add(to: menu, "Custom…", #selector(startCustom), key: "t")
        menu.addItem(.separator())

        add(to: menu, "Show Time Left", #selector(toggleDigits)).state = showDigits ? .on : .off
        if notificationStatus == .denied {
            add(to: menu, "⚠️ Notifications Off — Open Settings…", #selector(openNotificationSettings))
        }
        let quit = NSMenuItem(title: "Quit BarTimer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuDidClose(_ menu: NSMenu) {
        dismissFinished()
    }

    @discardableResult
    func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    func headerText() -> String {
        switch phase {
        case .idle:
            return "Not running"
        case .finished:
            return "Time's up"
        case .running(let end):
            return "\(format(remaining)) left of \(Int(total / 60)) min · ends \(Self.clock(end))"
        case .paused:
            return "Paused · \(format(remaining)) left"
        }
    }

    // MARK: - Drawing

    // Shown while idle. A template image, so it follows the menu bar's light or dark look.
    static let idleIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "BarTimer")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }()

    func render() {
        header?.title = headerText()
        guard let button = item.button else { return }
        // .imageLeading keeps room for the title even when it is empty, so use .imageOnly for the icon.
        switch phase {
        case .idle:
            button.image = Self.idleIcon
            button.imagePosition = .imageOnly
            button.title = ""
        case .finished:
            button.image = Self.bar(fraction: blinkOn ? 1 : 0, color: .systemRed)
            button.imagePosition = .imageLeading
            button.title = ""
        case .running, .paused:
            let fraction = total > 0 ? remaining / total : 0
            let color: NSColor
            if case .paused = phase { color = .systemGray } else { color = Self.color(for: fraction) }
            button.image = Self.bar(fraction: fraction, color: color)
            button.imagePosition = .imageLeading
            button.title = showDigits ? " " + format(remaining) : ""
        }
    }

    static func color(for fraction: Double) -> NSColor {
        if fraction > 0.5 { return .white }
        if fraction > 0.2 { return .systemOrange }
        return .systemRed
    }

    // The outline uses labelColor, so it shows on light and dark menu bars alike; the white cells
    // assume a dark one. Cells are filled from the left for the share of time left, so one cell
    // disappears from the right each time a tenth of the time passes (every 3 minutes for 30).
    static func bar(fraction: Double, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 56, height: 14), flipped: false) { rect in
            let frame = rect.insetBy(dx: 0.5, dy: 0.5)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            outline.stroke()

            // A cell stays while any of its time is left (round up): ten at the start, the last
            // one goes at 0:00. The small subtraction keeps float error such as
            // 0.3 * 10 = 3.0000000000000004 from counting one cell too many at a boundary.
            let lit = Int((min(max(fraction, 0), 1) * Double(segmentCount) - 1e-9).rounded(.up))
            let inner = frame.insetBy(dx: 2, dy: 2)
            let gap: CGFloat = 1
            let cell = (inner.width - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
            color.setFill()
            for i in 0..<lit {
                let x = inner.minX + CGFloat(i) * (cell + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: inner.minY, width: cell, height: inner.height),
                             xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        return image
    }

    // Keeps the width of the first reading for the whole run, so other menu bar items do not
    // shift when a digit drops off (padded with U+2007, a space as wide as a digit).
    func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if total >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        let text = String(format: "%d:%02d", s / 60, s % 60)
        return total >= 600 && s < 600 ? "\u{2007}" + text : text
    }

    // At most 600 minutes, so the end is today or tomorrow.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return (Calendar.current.isDateInToday(date) ? "" : "tomorrow ") + f.string(from: date)
    }

    // MARK: - Notifications

    // Show the banner even while the app is frontmost (for example with the menu open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    // Clicking or closing the notification also clears the time-up display.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await dismissFinished()
    }
}

let app = NSApplication.shared
// AppDelegate is @MainActor, so the synchronous top level of main.swift cannot create it directly.
// NSApplication holds its delegate weakly, so keep it in a top-level constant.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
