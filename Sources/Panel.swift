// 浮窗。nonactivatingPanel：从别处点它不抢焦点；只有菜单栏图标 / 热键进来才激活，⌘W 才有人接。
// 内容铺进标题栏（fullSizeContentView）：左边只留红点（收起），右边是「多久之前 ↻」。
// 没有黄点绿点：accessory app 没有 Dock 图标，最小化没处去；高度跟内容走，放大没意义。收起用红点或 ⌥⌘R。
// 背景是 macOS 26 的 Liquid Glass（NSGlassEffectView）；更早的系统退回 HUD 磨砂。

import AppKit

final class PanelController: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let root = NSView()   // 所有内容的父视图；外面包一层玻璃，见 backdrop()
    private var body: NSView?
    private let stamp = label("", Theme.font(10), Theme.tertiary)
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private var titlebarHeight: CGFloat = 28

    private var last: Snapshot?
    private var lastFromCache = false
    private var inflight = false
    private var timers: [Timer] = []
    private let live: Bool

    /// `live: false` 只用缓存渲染、不取数不起定时器，给 `--preview` 用。
    init(live: Bool = true) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        self.live = live
        super.init()
        configureWindow()
        configureHeader()

        last = loadCache()
        lastFromCache = last != nil
        render()
        guard live else { return }
        place()
        refresh()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() },
            // 倒计时和「多久之前」每分钟走一格，不等下一轮取数
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.render() },
        ]
    }

    private func configureWindow() {
        window.title = "额度"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 不在 styleMask 里的按钮系统仍会画成灰点，得显式藏掉
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        window.contentView = backdrop(root, glass: live)
        titlebarHeight = window.frame.height - window.contentLayoutRect.height
    }

    private func configureHeader() {
        let symbol = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        refreshButton.image = symbol
        refreshButton.isBordered = false
        refreshButton.contentTintColor = Theme.tertiary
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "刷新 · 5 分钟自动"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, refreshButton] as [NSView] {
            view.widthAnchor.constraint(equalToConstant: 14).isActive = true
            view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }

        let header = split([], [stamp, spinner, refreshButton], spacing: 6, alignment: .centerY)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),  // 让开红点
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titlebarHeight / 2),
        ])
    }

    // MARK: 显示与收起

    /// 红点：只收起，进程留在后台刷新。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard live else { return }
        UserDefaults.standard.set(Double(window.frame.minX), forKey: "panelX")
        UserDefaults.standard.set(Double(window.frame.maxY), forKey: "panelTop")
    }

    func show() {
        fit()
        window.orderFront(nil)
    }

    /// 从菜单栏图标 / 热键进来：激活 app，⌘W 才有响应者。
    func activate() {
        fit()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if window.isVisible && window.isKeyWindow { window.orderOut(nil) } else { activate() }
    }

    /// 高度跟内容走，上沿不动。
    private func fit() {
        guard let body else { return }
        root.layoutSubtreeIfNeeded()
        let height = titlebarHeight + 4 + body.fittingSize.height + Theme.inset
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Theme.width, height: height))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
    }

    /// 位置按上沿记；第一次启动贴屏幕右上角。
    private func place() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = window.frame.size
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "panelTop") != nil
        var x = saved ? CGFloat(defaults.double(forKey: "panelX")) : visible.maxX - size.width - 16
        var top = saved ? CGFloat(defaults.double(forKey: "panelTop")) : visible.maxY - 16
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        top = min(max(top, visible.minY + size.height), visible.maxY)
        window.setFrameOrigin(NSPoint(x: x, y: top - size.height))
    }

    // MARK: 取数

    @objc private func refreshClicked() { refresh() }

    func refresh() {
        guard !inflight else { return }
        inflight = true
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fresh = fetchSnapshot()
            DispatchQueue.main.async { self?.apply(fresh) }
        }
    }

    private func apply(_ fresh: Snapshot) {
        inflight = false
        setBusy(false)
        var snapshot = fresh
        snapshot.grok = merge(fresh.grok, onto: last?.grok)
        snapshot.claude = merge(fresh.claude, onto: last?.claude)
        last = snapshot
        lastFromCache = false
        if snapshot.hasNumber { saveCache(snapshot) }
        render()
    }

    private func setBusy(_ busy: Bool) {
        refreshButton.isHidden = busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func render() {
        if let snapshot = last {
            let stale = lastFromCache || snapshot.cards.contains { $0.stale }
            stamp.stringValue = (stale ? "缓存 · " : "") + relative(snapshot.fetchedAt)
        } else {
            stamp.stringValue = ""
        }

        body?.removeFromSuperview()
        let view = cardsView(last)
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: titlebarHeight + 4),
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.inset),
            view.widthAnchor.constraint(equalToConstant: Theme.content),
        ])
        body = view
        fit()
    }
}

/// 把 `content` 嵌进玻璃。不加 tint，底色跟系统一致；对比度靠 Theme 里的字色。
/// `glass: false` 给 `--preview`：玻璃和它里面的内容都画不进离屏位图，换一块实心深灰。
private func backdrop(_ content: NSView, glass: Bool) -> NSView {
    guard glass else {
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor
        content.layer?.cornerRadius = Theme.corner
        return content
    }
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Theme.corner
        glass.contentView = content
        return glass
    }
    let blur = NSVisualEffectView()
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.addSubview(content)
    content.frame = blur.bounds
    content.autoresizingMask = [.width, .height]
    return blur
}

/// `--preview out.png`：把真实面板（同一个 PanelController，只是不取数）离屏画成 PNG，
/// 改 UI 时看效果不用重装、不弹窗。背景是实心深灰，不是玻璃——玻璃只能看实机。
func renderPreview(to path: String) -> Bool {
    let panel = PanelController(live: false)
    guard let frameView = panel.window.contentView?.superview else { return false }
    frameView.layoutSubtreeIfNeeded()

    guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}
