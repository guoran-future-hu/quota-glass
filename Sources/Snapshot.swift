import Foundation

/// 两家并行取，各自失败互不影响。
func fetchSnapshot() -> Snapshot {
    var grok: Card?
    var claude: Card?
    DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 { grok = fetchGrok() } else { claude = fetchClaude() }
    }
    return Snapshot(grok: grok!, claude: claude!, fetchedAt: Date())
}

/// 这一轮整张卡没数、上一轮有：沿用上一轮的数，标 stale，错误照常显示。
/// Claude 的 usage 接口 429 很常见，靠这个不让面板变空。
func merge(_ fresh: Card, onto previous: Card?) -> Card {
    guard let previous, fresh.error != nil, !fresh.hasNumber, previous.hasNumber else { return fresh }
    var kept = previous
    kept.error = fresh.error
    kept.stale = true
    kept.source = fresh.source.isEmpty ? previous.source : fresh.source
    return kept
}

// MARK: - 缓存（不含 token）

private let cacheFile = home("Library/Caches/mac-rate-limits/usage.json")

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

func loadCache() -> Snapshot? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: cacheFile) else { return nil }
    return try? decoder.decode(Snapshot.self, from: data)
}

func saveCache(_ snapshot: Snapshot) {
    try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? jsonEncoder.encode(snapshot).write(to: cacheFile, options: .atomic)
}
