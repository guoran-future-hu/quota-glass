// 凭证只读：每轮重读文件里当前的 access token，不 refresh、不写回。
// xAI 每次刷新会轮转 refresh token；Claude 的 refresh token 是一次性的，
// 自己去续会把 Hermes 或 Claude Code 踢下线。过期就等它们续完，下一轮重读。

import Foundation

struct Bearer {
    var token: String
    var source: String
    var expiresAt: Date?
    var expired: Bool { expiresAt.map { $0.timeIntervalSinceNow < 0 } ?? false }
}

// MARK: - Grok

func grokBearer() throws -> Bearer {
    switch readJSON(home(".hermes/auth.json")) {
    case .success(let root):
        if let bearer = grokFromHermes(root) { return bearer }
    case .failure(.missing):
        break
    case .failure(let problem):
        throw Failure("Hermes auth.json \(problem.text)。可能正在写入，下一轮再试。")
    }
    switch readJSON(home(".grok/auth.json")) {
    case .success(let root):
        if let bearer = grokFromCLI(root) { return bearer }
        throw Failure("找到了 Grok 凭证文件，但里面没有 access token。")
    case .failure(.missing):
        throw Failure("没有 xAI 登录。Hermes 的 xai-oauth 在 ~/.hermes/auth.json，或者本机 grok login。")
    case .failure(let problem):
        throw Failure("~/.grok/auth.json \(problem.text)。")
    }
}

/// `providers.xai-oauth.tokens`，否则 `credential_pool.xai-oauth[]` 里第一个有 token 的。
private func grokFromHermes(_ root: [String: Any]) -> Bearer? {
    let providers = root["providers"] as? [String: Any]
    if let state = providers?["xai-oauth"] as? [String: Any],
       let tokens = state["tokens"] as? [String: Any],
       let access = nonEmpty(tokens["access_token"]) {
        return Bearer(token: access, source: "Hermes xAI OAuth",
                      expiresAt: xaiExpiry(tokens, lastRefresh: state["last_refresh"]))
    }
    let pool = (root["credential_pool"] as? [String: Any])?["xai-oauth"] as? [[String: Any]] ?? []
    for entry in pool {
        if let access = nonEmpty(entry["access_token"]) {
            return Bearer(token: access, source: "Hermes xAI OAuth",
                          expiresAt: xaiExpiry(entry, lastRefresh: entry["last_refresh"]))
        }
    }
    return nil
}

/// `grok login` 的文件按 issuer 分条，优先 auth.x.ai 那条。
private func grokFromCLI(_ root: [String: Any]) -> Bearer? {
    var fallback: Bearer?
    for (issuer, value) in root {
        guard let entry = value as? [String: Any],
              let access = nonEmpty(entry["key"]) ?? nonEmpty(entry["access_token"]) else { continue }
        let bearer = Bearer(token: access, source: "grok login",
                            expiresAt: xaiExpiry(entry, lastRefresh: nil) ?? dateField(entry["expires_at"]))
        if issuer.contains("auth.x.ai") { return bearer }
        fallback = fallback ?? bearer
    }
    return fallback
}

/// JWT 的 exp；不是 JWT 就用 last_refresh + expires_in。
private func xaiExpiry(_ tokens: [String: Any], lastRefresh: Any?) -> Date? {
    if let access = nonEmpty(tokens["access_token"]) ?? nonEmpty(tokens["key"]),
       let exp = jwtExpiry(access) {
        return exp
    }
    guard let last = parseDate(lastRefresh as? String), let seconds = number(tokens["expires_in"]) else { return nil }
    return last.addingTimeInterval(seconds)
}

// MARK: - Claude

/// Hermes 那份和 Claude Code 那份，未过期的优先。不读钥匙串。
func claudeBearer() throws -> Bearer {
    let hermes = readJSON(home(".hermes/.anthropic_oauth.json")).flatMap { root in
        bearer(root["accessToken"], expires: root["expiresAt"], source: "Hermes Claude OAuth")
    }
    let code = readJSON(home(".claude/.credentials.json")).flatMap { root in
        let oauth = root["claudeAiOauth"] as? [String: Any]
        return bearer(oauth?["accessToken"], expires: oauth?["expiresAt"], source: "Claude Code")
    }
    let found = [hermes, code].compactMap { try? $0.get() }
    if let bearer = found.first(where: { !$0.expired }) ?? found.first { return bearer }

    if case .failure(let problem) = hermes, problem != .missing {
        throw Failure("Hermes 的 Claude 凭证\(problem.text)。")
    }
    if case .failure(let problem) = code, problem != .missing {
        throw Failure("Claude Code 凭证\(problem.text)。")
    }
    throw Failure("没有 Claude OAuth。看 ~/.hermes/.anthropic_oauth.json 或 ~/.claude/.credentials.json。不读钥匙串。")
}

private func bearer(_ token: Any?, expires: Any?, source: String) -> Result<Bearer, FileProblem> {
    guard let access = nonEmpty(token) else { return .failure(.missing) }
    return .success(Bearer(token: access, source: source, expiresAt: dateField(expires)))
}

// MARK: - grok.cookie（可选，有它就不碰 Safari）

func grokCookie() -> String? {
    let url = home("Library/Application Support/RateLimits/grok.cookie")
    guard let raw = try? String(contentsOf: url, encoding: .utf8),
          var line = raw.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
    line = line.trimmingCharacters(in: .whitespaces)
    if line.lowercased().hasPrefix("cookie:") {
        line = line.dropFirst("cookie:".count).trimmingCharacters(in: .whitespaces)
    }
    return line.isEmpty ? nil : line
}
