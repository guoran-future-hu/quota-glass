import AppKit
import Carbon.HIToolbox

/// 全局热键 ⌥⌘R。菜单栏图标被刘海挡住时这是唯一稳定的入口。Carbon 注册，不需要辅助功能权限。
final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.shared.action?()
            return noErr
        }, 1, &pressed, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x524C_4D54), id: 1)  // 'RLMT'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

/// 菜单栏图标：左键叫出面板并激活；右键 / ⌃-左键出菜单。
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private weak var panel: PanelController?

    init(panel: PanelController) {
        self.panel = panel
        super.init()
        let symbol = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "额度")
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.toolTip = "额度 · ⌥⌘R"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        menu.addItem(withTitle: "显示面板", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(.separator())
        let hint = menu.addItem(withTitle: "热键 ⌥⌘R", action: nil, keyEquivalent: "")
        hint.isEnabled = false
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary, let event, let button = item.button {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            panel?.activate()
        }
    }

    @objc private func show() { panel?.activate() }
    @objc private func refresh() { panel?.refresh() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    private var status: StatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        let panel = PanelController()
        self.panel = panel
        status = StatusItem(panel: panel)
        HotKey.shared.action = { [weak panel] in panel?.toggle() }
        HotKey.shared.register()
        panel.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 收起后 `open -a RateLimits` 也能叫回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.activate()
        return true
    }

    /// accessory app 没有自带主菜单，⌘W / ⌘H / ⌘Q 就没有响应者。手搭最小的一套。
    private func mainMenu() -> NSMenu {
        func submenu(_ title: String, _ items: [(String, Selector, String)]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            for (name, action, key) in items { menu.addItem(withTitle: name, action: action, keyEquivalent: key) }
            let item = NSMenuItem()
            item.submenu = menu
            return item
        }
        let main = NSMenu()
        main.addItem(submenu("额度", [
            ("关于 额度", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            ("隐藏 额度", #selector(NSApplication.hide(_:)), "h"),
            ("退出 额度", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("文件", [("关闭窗口", #selector(NSWindow.performClose(_:)), "w")]))
        return main
    }
}
