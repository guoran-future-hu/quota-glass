// Grok 两档：
// - 周池：Settings → Usage 那个共享池，OAuth 能读。先 billing JSON，缺百分比再补 gRPC。
// - 2 小时短窗：按模型计请求次数，只认浏览器会话（OAuth 打 /rest/rate-limits 是 403）。
//   有 grok.cookie 走 HTTP，否则借 Safari 里已登录的 grok.com 标签页。

import AppKit

func fetchGrok() -> Card {
    let session = fetchGrokSession()
    var sources: [String] = []
    var week: Reading
    var failure: String?
    do {
        let bearer = try grokBearer()
        sources.append(bearer.source)
        guard !bearer.expired else { throw Failure(expiredNote(bearer.expiresAt)) }
        week = weekReading(try grokWeek(bearer.token))
    } catch {
        failure = error.localizedDescription
        week = .unavailable(Span.week, error.localizedDescription)
    }
    if session.reading.usedPercent != nil { sources.append("\(session.source) 短窗") }
    return Card(
        name: "Grok", source: sources.isEmpty ? "未登录" : sources.joined(separator: " + "),
        readings: [session.reading, week], error: failure
    )
}

// MARK: - 周池

struct GrokWeek {
    var percent: Double?
    var start: Date?
    var end: Date?
    var monthly = false
    var products: [(name: String, percent: Double)] = []

    var isEmpty: Bool { percent == nil && end == nil && products.isEmpty }

    /// JSON 缺的字段拿 gRPC 那份补。
    func filled(from other: GrokWeek) -> GrokWeek {
        var merged = self
        merged.percent = percent ?? other.percent
        merged.start = start ?? other.start
        merged.end = end ?? other.end
        merged.monthly = monthly || other.monthly
        if products.isEmpty { merged.products = other.products }
        return merged
    }
}

func grokWeek(_ token: String) throws -> GrokWeek {
    let json: GrokWeek
    do {
        json = try billingJSON(token)
    } catch {
        return try billingProto(token)
    }
    guard json.percent == nil, let proto = try? billingProto(token) else { return json }
    return json.filled(from: proto)
}

private func billingJSON(_ token: String) throws -> GrokWeek {
    let data = try fetchOK(makeRequest(
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits", bearer: token,
        headers: ["X-XAI-Token-Auth": "xai-grok-cli", "x-grok-client-surface": "menu-bar"]
    ))
    guard let week = parseCreditsJSON(data) else { throw Failure("billing JSON 里没有周池字段") }
    return week
}

private func billingProto(_ token: String) throws -> GrokWeek {
    let data = try fetchOK(makeRequest(
        "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig", method: "POST", bearer: token,
        headers: ["Content-Type": "application/grpc-web+proto", "X-Grpc-Web": "1"],
        body: Data(count: 5)  // 空消息的 gRPC-web 帧
    ))
    guard let week = parseCreditsProto(data) else { throw Failure("周池响应里没有百分比，也没有重置时间") }
    return week
}

func parseCreditsJSON(_ data: Data) -> GrokWeek? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let config = unwrapConfig(root)
    let period = first(config, "currentPeriod", "current_period") as? [String: Any]
    let products = (first(config, "productUsage", "product_usage") as? [[String: Any]] ?? []).compactMap {
        item -> (name: String, percent: Double)? in
        let name = prettyProduct(first(item, "product", "name") as? String ?? "")
        guard !name.isEmpty, let percent = normalizePercent(number(first(item, "usagePercent", "usage_percent")))
        else { return nil }
        return (name, percent)
    }
    let week = GrokWeek(
        percent: normalizePercent(number(first(config, "creditUsagePercent", "credit_usage_percent"))),
        start: parseDate(period?["start"] as? String),
        end: parseDate(period?["end"] as? String),
        monthly: (period?["type"] as? String ?? "").contains("MONTH"),
        products: products
    )
    return week.isEmpty ? nil : week
}

/// 周池字段有时在顶层，有时包在 config / data / billing 里。
private func unwrapConfig(_ root: [String: Any]) -> [String: Any] {
    func looksRight(_ object: [String: Any]) -> Bool {
        object["creditUsagePercent"] != nil || object["currentPeriod"] != nil
    }
    if looksRight(root) { return root }
    for key in ["config", "data", "billing"] {
        guard let inner = root[key] as? [String: Any] else { continue }
        if let nested = inner["config"] as? [String: Any] { return nested }
        if looksRight(inner) { return inner }
    }
    return root
}

/// GrokCreditsConfig：1 用量百分比，4/5 起止，7 按产品拆分，8 当前周期（1 = 月）。
func parseCreditsProto(_ data: Data) -> GrokWeek? {
    for payload in grpcPayloads(data) {
        let top = Proto(payload)
        func looksRight(_ proto: Proto) -> Bool { proto.float(1) != nil || proto.message(8) != nil }
        guard let config = top.message(1).flatMap({ looksRight($0) || $0.timestamp(4) != nil || $0.timestamp(5) != nil ? $0 : nil })
                ?? (looksRight(top) ? top : nil) else { continue }
        let period = config.message(8)
        let week = GrokWeek(
            percent: normalizePercent(config.float(1)),
            start: period?.timestamp(2) ?? config.timestamp(4),
            end: period?.timestamp(3) ?? config.timestamp(5),
            monthly: period?.varint(1) == 1,
            products: config.messages(7).compactMap { product in
                guard let percent = normalizePercent(product.float(2)) else { return nil }
                if let text = product.string(1), !text.isEmpty,
                   text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    return (prettyProduct(text), percent)
                }
                return product.varint(1).map { ("产品 \($0)", percent) }
            }
        )
        if week.percent != nil || week.end != nil { return week }
    }
    return nil
}

/// `GrokBuild` / `BUILD` → `Build`；不认识的原样留着。
private func prettyProduct(_ raw: String) -> String {
    let name = raw.hasPrefix("Grok") ? String(raw.dropFirst(4)) : raw
    let shouting = ["CHAT": "Chat", "BUILD": "Build", "IMAGINE": "Imagine", "VOICE": "Voice"]
    return shouting[name] ?? name
}

private func weekReading(_ week: GrokWeek) -> Reading {
    var notes: [String] = []
    if week.percent == nil { notes.append("窗口在，百分比没给。不当作 0。") }
    if !week.products.isEmpty {
        notes.append("构成 " + week.products.prefix(6).map { "\($0.name) \(formatPct($0.percent))" }
            .joined(separator: " · "))
    }
    return Reading(
        title: week.monthly ? Span.month : Span.week,
        subtitle: week.monthly ? "月池" : "共享池",
        usedPercent: week.percent,
        resetsAt: week.end,
        note: notes.joined(separator: " ")
    )
}

// MARK: - 2 小时短窗

/// 一个模型的 /rest/rate-limits 原始应答。
struct Probe {
    let model: String
    let status: Int     // -1 = 传输层失败，body 是原因
    let body: String
}

/// `grok-4.7` 在这个接口上是 404 Model not found，所以默认探 `grok-4` 和 `fast`。
func sessionModels() -> [String] {
    let listed = (ProcessInfo.processInfo.environment["GROK_RATE_LIMIT_MODEL"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return listed.isEmpty ? ["grok-4", "fast"] : listed
}

private func fetchGrokSession() -> (reading: Reading, source: String) {
    let models = sessionModels()
    let cookie = grokCookie()
    let source = cookie == nil ? "Safari 标签页" : "grok.cookie"
    do {
        let probes = try cookie.map { probeWithCookie($0, models) } ?? probeWithSafari(models)
        return (sessionReading(probes, source: source), source)
    } catch {
        return (.unavailable(Span.grokSession, error.localizedDescription), source)
    }
}

private func probeWithCookie(_ cookie: String, _ models: [String]) -> [Probe] {
    models.map { model in
        let request = makeRequest(
            "https://grok.com/rest/rate-limits", method: "POST",
            headers: ["Content-Type": "application/json", "Cookie": cookie, "Origin": "https://grok.com"],
            body: try? JSONSerialization.data(withJSONObject: ["modelName": model])
        )
        do {
            let (status, body) = try send(request)
            return Probe(model: model, status: status, body: String(decoding: body, as: UTF8.self))
        } catch {
            return Probe(model: model, status: -1, body: error.localizedDescription)
        }
    }
}

/// 在 grok.com 标签页里发同源请求，取完就完，不落 cookie。
private let safariScript = [
    "on run argv",
    "if application \"Safari\" is not running then return \"SAFARI_CLOSED\"",
    "tell application \"Safari\"",
    "repeat with w in windows",
    "repeat with t in tabs of w",
    "try",
    "if (URL of t as string) starts with \"https://grok.com\" then return do JavaScript (item 1 of argv) in t",
    "end try",
    "end repeat",
    "end repeat",
    "end tell",
    "return \"NO_GROK_TAB\"",
    "end run",
]

private func probeWithSafari(_ models: [String]) throws -> [Probe] {
    guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
        throw Failure("Safari 没开。短窗要靠它的登录态；不想依赖它就放一个 grok.cookie。")
    }
    let list = String(decoding: try JSONSerialization.data(withJSONObject: models), as: UTF8.self)
    // 同步 XHR；body 截到 4000 字，防止错误页把 osascript 的管道撑满。
    let js = """
    JSON.stringify(\(list).map(function (m) { try { var x = new XMLHttpRequest(); \
    x.open('POST', '/rest/rate-limits', false); x.setRequestHeader('Content-Type', 'application/json'); \
    x.send(JSON.stringify({modelName: m})); return {model: m, status: x.status, body: x.responseText.slice(0, 4000)}; \
    } catch (e) { return {model: m, status: -1, body: String(e)}; } }))
    """
    let output = try osascript(safariScript, args: [js], timeout: 10)
    switch output {
    case "SAFARI_CLOSED": throw Failure("Safari 没开")
    case "NO_GROK_TAB": throw Failure("Safari 里没有开着的 grok.com 标签页")
    case "": throw Failure("Safari 没返回数据，可能没给「自动化」权限")
    default: break
    }
    guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else {
        throw Failure("Safari 返回的不是预期 JSON")
    }
    return rows.map {
        Probe(model: $0["model"] as? String ?? "?", status: Int(number($0["status"]) ?? -1),
              body: $0["body"] as? String ?? "")
    }
}

private func osascript(_ lines: [String], args: [String], timeout: TimeInterval) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = lines.flatMap { ["-e", $0] } + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { throw Failure("起不来 osascript") }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        throw Failure("Safari \(Int(timeout)) 秒没应答。要是弹了「允许控制 Safari」，点允许。")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct SessionWindow {
    let model: String
    let used: Double
    let remaining: Int
    let total: Int
    let seconds: Int

    init?(_ probe: Probe) {
        guard probe.status == 200,
              let object = try? JSONSerialization.jsonObject(with: Data(probe.body.utf8)) as? [String: Any],
              let total = number(object["totalQueries"]), total > 0,
              let remaining = number(object["remainingQueries"]) else { return nil }
        model = probe.model
        used = min(100, max(0, (total - remaining) / total * 100))
        self.remaining = Int(remaining)
        self.total = Int(total)
        seconds = Int(number(object["windowSizeSeconds"]) ?? 0)
    }
}

/// 条形取用得最多的模型；接口不给重置时刻，所以第二行写各模型剩余次数。
private func sessionReading(_ probes: [Probe], source: String) -> Reading {
    let windows = probes.compactMap(SessionWindow.init)
    guard let worst = windows.max(by: { $0.used < $1.used }) else {
        let reason = probes.first.map { probe in
            let body = scrub(probe.body)
            return probe.status < 0 ? "\(probe.model) \(body)" : "\(probe.model) HTTP \(probe.status) \(body)"
        }
        return .unavailable(Span.grokSession, reason ?? "短窗读不到")
    }
    let title = worst.seconds > 0 ? windowTitle(worst.seconds) : Span.grokSession
    let counts = windows.map { "\($0.model) \($0.remaining)/\($0.total)" }.joined(separator: " · ")
    return Reading(
        title: title,
        subtitle: "\(title)滚动窗 · 剩余次数 \(counts)",
        usedPercent: worst.used,
        note: "\(source) · 接口不给重置时刻",
        caption: "剩余 \(counts)"
    )
}
