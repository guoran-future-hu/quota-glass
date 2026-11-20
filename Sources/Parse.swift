import Foundation

func home(_ path: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
}

func nonEmpty(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    return text
}

func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

/// 第一个存在的键。同一个字段，接口有时 camelCase 有时 snake_case。
func first(_ object: [String: Any]?, _ keys: String...) -> Any? {
    guard let object else { return nil }
    return keys.lazy.compactMap { object[$0] }.first { !($0 is NSNull) }
}

private let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    return isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
}

/// ISO 字符串，或 Unix 秒 / 毫秒。
func dateField(_ value: Any?) -> Date? {
    if let text = value as? String { return parseDate(text) }
    guard let raw = number(value), raw > 0 else { return nil }
    return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
}

/// 0…1 当作分数，0…100 当作百分数。缺字段由调用方保持 nil，这里的 0 是接口明确给的 0。
func normalizePercent(_ raw: Double?) -> Double? {
    guard let raw, raw.isFinite, raw >= 0, raw <= 100 else { return nil }
    return raw <= 1 ? raw * 100 : raw
}

/// 响应体上正文前：抹掉 token，压成一行，截短。
func scrub(_ text: String) -> String {
    let patterns = [
        #"sk-ant-[A-Za-z0-9_\-]+"#,
        #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
    ]
    var cleaned = patterns.reduce(text) {
        $0.replacingOccurrences(of: $1, with: "[redacted]", options: .regularExpression)
    }
    cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
    return String(cleaned.prefix(180))
}

func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = number(object["exp"]) else { return nil }
    return Date(timeIntervalSince1970: exp)
}

enum FileProblem: Error {
    case missing, unreadable, malformed

    var text: String {
        switch self {
        case .missing: "不存在"
        case .unreadable: "读不了"
        case .malformed: "不是合法 JSON"
        }
    }
}

func readJSON(_ url: URL) -> Result<[String: Any], FileProblem> {
    guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
    guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure(.malformed)
    }
    return .success(object)
}
