import AppKit

let arguments = CommandLine.arguments

// 只取数、不开窗。
if arguments.contains("--json") {
    let snapshot = fetchSnapshot()
    if let data = try? jsonEncoder.encode(snapshot) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    exit(snapshot.hasNumber ? 0 : 1)
}

// 用缓存离屏渲染一张面板截图，不取数、不开窗。
if let flag = arguments.firstIndex(of: "--preview") {
    let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "preview.png"
    _ = NSApplication.shared
    exit(renderPreview(to: path) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
