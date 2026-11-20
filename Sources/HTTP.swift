import Foundation

func makeRequest(
    _ url: String, method: String = "GET", bearer: String? = nil,
    headers: [String: String] = [:], body: Data? = nil
) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 20)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    return request
}

/// 同步请求，只在后台线程调。传输层失败才抛；非 2xx 照常返回。
func send(_ request: URLRequest) throws -> (status: Int, body: Data) {
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<(Int, Data), Error> = .failure(Failure("没有响应"))
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        if let error {
            outcome = .failure(Failure(error.localizedDescription))
        } else if let http = response as? HTTPURLResponse {
            outcome = .success((http.statusCode, data ?? Data()))
        } else {
            outcome = .failure(Failure("不是 HTTP 响应"))
        }
    }
    task.resume()
    if done.wait(timeout: .now() + 25) == .timedOut {
        task.cancel()
        throw Failure("超时")
    }
    return try outcome.get()
}

/// 非 2xx 抛 `HTTP <code> <说明>`：响应是 JSON 且带 message 就只取 message，否则整段 body（已 scrub）。
func fetchOK(_ request: URLRequest) throws -> Data {
    let (status, body) = try send(request)
    guard (200..<300).contains(status) else {
        let text = scrub(apiMessage(body) ?? String(decoding: body, as: UTF8.self))
        throw Failure(text.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(text)")
    }
    return body
}

/// `{"error":{"message":…}}`、`{"message":…}`、`{"error":"…"}` 三种都认。
private func apiMessage(_ body: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return nonEmpty((root["error"] as? [String: Any])?["message"]) ?? nonEmpty(root["message"]) ?? nonEmpty(root["error"])
}
