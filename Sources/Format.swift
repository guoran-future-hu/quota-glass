import Foundation

func formatNumber(_ value: Double) -> String {
    if value < 10, value != value.rounded() { return String(format: "%.1f", value) }
    return String(format: "%.0f", value.rounded())
}

func formatPct(_ value: Double) -> String { formatNumber(value) + "%" }

/// 正好整小时写「2 小时」，否则写成时长。
func windowTitle(_ seconds: Int) -> String {
    seconds > 0 && seconds % 3600 == 0 ? "\(seconds / 3600) 小时" : duration(seconds)
}

func duration(_ seconds: Int) -> String {
    if seconds < 3600 { return "\(max(seconds / 60, 1)) 分钟" }
    if seconds < 86_400 { return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分" }
    return "\(seconds / 86_400) 天 \((seconds % 86_400) / 3600) 小时"
}

private func zhFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = format
    return formatter
}
private let todayFormat = zhFormatter("今天 HH:mm")
private let tomorrowFormat = zhFormatter("明天 HH:mm")
private let dayFormat = zhFormatter("M月d日 HH:mm")

func formatReset(_ date: Date) -> String {
    let calendar = Calendar.current
    let formatter = calendar.isDateInToday(date) ? todayFormat
        : calendar.isDateInTomorrow(date) ? tomorrowFormat : dayFormat
    return formatter.string(from: date)
}

func countdown(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    return seconds <= 0 ? "已到重置点" : "\(duration(seconds))后重置"
}

func relative(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 45 { return "刚刚" }
    if seconds < 3600 { return "\(max(seconds / 60, 1)) 分钟前" }
    if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
    return "\(seconds / 86_400) 天前"
}

func expiredNote(_ expiresAt: Date?) -> String {
    let stamp = expiresAt.map { "（\(formatReset($0))）" } ?? ""
    return "access token 已过期\(stamp)。窗口不续期，等它自己续完再刷新。"
}
