import Foundation

/// 窗口类型的正文用词。用中文词不用 `2h` / `7d`：四个缩写堆一列容易看串。
enum Span {
    static let grokSession = "2 小时"
    static let claudeSession = "5 小时"
    static let week = "7 天"
    static let month = "本月"
}

/// 一档额度。
struct Reading: Codable {
    var title: String           // 窗口类型，见 `Span`
    var subtitle = ""           // tooltip 首行：窗口全称和明细
    var usedPercent: Double?    // nil = 接口没给，不当作 0
    var resetsAt: Date?
    var note = ""               // tooltip 尾行：来源、失败原因
    var model: String?          // 模型级周额度（Opus / Fable）才有
    var caption: String?        // 没有重置时刻时，正文第二行写这个

    static func unavailable(_ title: String, _ note: String) -> Reading {
        Reading(title: title, note: note)
    }
}

/// 一个提供商。
struct Card: Codable {
    var name: String
    var source: String
    var readings: [Reading]
    var footnote = ""
    var error: String?
    var stale = false           // 这一轮失败，显示的是上一轮的数

    var hasNumber: Bool { readings.contains { $0.usedPercent != nil } }

    /// 整张卡读不到：两档都写同一个原因。
    static func failed(_ name: String, source: String, session: String, _ message: String) -> Card {
        Card(
            name: name, source: source,
            readings: [.unavailable(session, message), .unavailable(Span.week, message)],
            error: message
        )
    }
}

struct Snapshot: Codable {
    var grok: Card
    var claude: Card
    var fetchedAt: Date

    var cards: [Card] { [grok, claude] }
    var hasNumber: Bool { grok.hasNumber || claude.hasNumber }
}

/// 给人看的失败原因，直接上正文或 tooltip。
struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
