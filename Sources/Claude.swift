// Claude：`GET /api/oauth/usage`。five_hour 是订阅里的 session limit，seven_day 是全模型周额度；
// 接口若还带 Opus / Sonnet / Fable 的单独周额度，各多一行。

import Foundation

func fetchClaude() -> Card {
    var source = "未登录"
    do {
        let bearer = try claudeBearer()
        source = bearer.source
        guard !bearer.expired else { throw Failure(expiredNote(bearer.expiresAt)) }
        let data = try fetchOK(makeRequest(
            "https://api.anthropic.com/api/oauth/usage", bearer: bearer.token,
            headers: ["anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-cli/2.1.80 (external, cli)"]
        ))
        guard let parsed = claudeReadings(data) else { throw Failure("usage 响应不是预期的 JSON") }
        return Card(name: "Claude", source: source, readings: parsed.readings, footnote: parsed.extra)
    } catch {
        return .failed("Claude", source: source, session: Span.claudeSession, error.localizedDescription)
    }
}

/// 两种形状都认：新的 `limits[]`（kind = session / weekly_all / weekly_scoped），
/// 旧的 `five_hour` / `seven_day` / `seven_day_<model>`。新的优先。
func claudeReadings(_ data: Data) -> (readings: [Reading], extra: String)? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    func session(_ percent: Double?, _ resets: Date?) -> Reading {
        Reading(title: Span.claudeSession, subtitle: "5 小时滚动窗", usedPercent: percent, resetsAt: resets)
    }
    func week(_ percent: Double?, _ resets: Date?) -> Reading {
        Reading(title: Span.week, subtitle: "7 天 · 全模型", usedPercent: percent, resetsAt: resets)
    }
    var sessionRow: Reading?
    var weekRow: Reading?
    var scoped: [Reading] = []
    var seen: Set<String> = []
    func addScoped(_ name: String, _ percent: Double?, _ resets: Date?) {
        // 只收给人看的名字：带下划线的是内部 id
        guard !name.isEmpty, !name.contains("_"), name.count < 40, seen.insert(name).inserted else { return }
        scoped.append(Reading(title: Span.week, subtitle: "7 天 · \(name)", usedPercent: percent,
                              resetsAt: resets, model: name))
    }

    for item in root["limits"] as? [[String: Any]] ?? [] {
        let percent = number(first(item, "percent", "utilization"))
        let resets = dateField(item["resets_at"])
        switch item["kind"] as? String ?? "" {
        case "session": sessionRow = session(percent, resets)
        case "weekly_all": weekRow = week(percent, resets)
        case let kind where kind.contains("week"):
            if let name = scopeName(item) { addScoped(name, percent, resets) }
        default: break
        }
    }
    if sessionRow == nil, let window = usageWindow(root["five_hour"]) { sessionRow = session(window.percent, window.resets) }
    if weekRow == nil, let window = usageWindow(root["seven_day"]) { weekRow = week(window.percent, window.resets) }
    for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet"), ("seven_day_cowork", "Cowork")] {
        if let window = usageWindow(root[key]) { addScoped(name, window.percent, window.resets) }
    }
    for item in root["model_scoped"] as? [[String: Any]] ?? [] {
        guard let name = nonEmpty(item["display_name"]) else { continue }
        addScoped(name, number(first(item, "utilization", "percent")), dateField(item["resets_at"]))
    }

    let absent = "接口没有这档额度"
    let readings = [sessionRow ?? .unavailable(Span.claudeSession, absent), weekRow ?? .unavailable(Span.week, absent)]
    return (readings + scoped, extraUsage(root["extra_usage"]))
}

private func scopeName(_ item: [String: Any]) -> String? {
    let scope = item["scope"] as? [String: Any]
    return nonEmpty((scope?["model"] as? [String: Any])?["display_name"])
        ?? nonEmpty(scope?["display_name"]) ?? nonEmpty(item["display_name"])
}

private func usageWindow(_ value: Any?) -> (percent: Double, resets: Date?)? {
    guard let object = value as? [String: Any],
          let percent = number(first(object, "utilization", "used_percentage", "percent")) else { return nil }
    return (percent, dateField(object["resets_at"]))
}

/// 额外用量（按量付费）开着才写；金额单位是分。
private func extraUsage(_ value: Any?) -> String {
    guard let usage = value as? [String: Any], usage["is_enabled"] as? Bool == true,
          let used = number(usage["used_credits"]) else { return "" }
    let currency = nonEmpty(usage["currency"]) ?? "USD"
    if let limit = number(usage["monthly_limit"]) {
        return String(format: "额外用量 %@ %.2f / %.2f", currency, used / 100, limit / 100)
    }
    return String(format: "额外用量已用 %@ %.2f", currency, used / 100)
}
