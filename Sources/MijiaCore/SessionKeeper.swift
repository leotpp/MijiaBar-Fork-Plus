import Foundation

// 同步失效与提交共用短锁，防止退出后在途续期复活旧登录；网络等待不持锁。
private final class SessionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.lock(); defer { lock.unlock() }; valid = false }
    func checked<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw CloudError.authExpired }
        return try body()
    }
}

actor SessionKeeper {
    struct Snapshot: Sendable { let session: Session; let generation: UInt64 }
    private var session: Session
    private var generation: UInt64 = 0
    private var flight: (id: UUID, task: Task<Session, Error>)?
    private var retryAfter: Date?
    private let validity = SessionValidity()
    private let refresh: @Sendable (Session) async throws -> Session
    private let commit: @Sendable (Session) throws -> Session
    private let clock: @Sendable () -> Date
    private let changed: @Sendable (Session) async -> Void

    init(session: Session, refresh: @escaping @Sendable (Session) async throws -> Session,
         commit: @escaping @Sendable (Session) throws -> Session = { try Session.persistRefresh($0) },
         clock: @escaping @Sendable () -> Date = { Date() },
         changed: @escaping @Sendable (Session) async -> Void = { _ in }) {
        self.session = session; self.refresh = refresh; self.commit = commit; self.clock = clock; self.changed = changed
    }
    nonisolated func invalidate() { validity.invalidate() }
    func snapshot() async throws -> Snapshot {
        try validity.checked { }
        if let retryAfter, clock() < retryAfter { throw CloudError.authExpired }
        if flight != nil { return try await recover(rejectedGeneration: generation) }
        return Snapshot(session: session, generation: generation)
    }
    func coolDown(generation rejected: UInt64) {
        if generation == rejected { retryAfter = clock().addingTimeInterval(60) }
    }
    func recover(rejectedGeneration: UInt64) async throws -> Snapshot {
        try validity.checked { }
        if let retryAfter, clock() < retryAfter { throw CloudError.authExpired }
        if rejectedGeneration != generation { return Snapshot(session: session, generation: generation) }
        let active: (id: UUID, task: Task<Session, Error>)
        if let flight { active = flight }
        else {
            let old = session, refresh = refresh
            active = (UUID(), Task { try await refresh(old) }); flight = active
        }
        do {
            let replacement = try await active.task.value
            if flight?.id == active.id {
                let stored = try validity.checked { try commit(replacement) }
                session = stored; generation += 1; flight = nil; retryAfter = nil
                await changed(stored)
            }
            try validity.checked { }
            try Task.checkCancellation()
            return Snapshot(session: session, generation: generation)
        } catch {
            if flight?.id == active.id { flight = nil; retryAfter = clock().addingTimeInterval(60) }
            if error is CancellationError { throw error }
            throw CloudError.authExpired
        }
    }
}

// 每次换票使用独立 ephemeral cookie jar，不读取其他登录留下的 Cookie。
struct AccountLogin {
    let http: URLSession
    let cookies: HTTPCookieStorage
    init(configuration: URLSessionConfiguration = .ephemeral) {
        cookies = configuration.httpCookieStorage!
        configuration.timeoutIntervalForRequest = 30
        http = URLSession(configuration: configuration)
    }
    static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == ";" || $0.isNewline })
    }
    func finish(_ object: [String: Any], region: String, previous: Session? = nil) async throws -> Session {
        let userId = anyString(object["userId"])
        guard Self.validCredential(userId), previous == nil || previous?.userId == userId,
              let security = object["ssecurity"] as? String, let decoded = Data(base64Encoded: security), !decoded.isEmpty,
              let location = (object["location"] as? String).flatMap(URL.init(string:)),
              location.scheme == "https", let host = location.host,
              host == "sts.api.io.mi.com" || host.hasSuffix(".sts.api.io.mi.com"),
              location.user == nil, location.password == nil else { throw CloudError.authExpired }
        for cookie in cookies.cookies ?? [] where cookie.name == "serviceToken" { cookies.deleteCookie(cookie) }
        let (_, response) = try await http.data(from: location)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = cookies.cookies(for: location)?.first(where: { $0.name == "serviceToken" })?.value,
              Self.validCredential(token) else { throw CloudError.authExpired }
        func credential(_ name: String, fallback: String?) throws -> String? {
            guard let raw = object[name] else { return fallback }
            guard let value = raw as? String, Self.validCredential(value) else { throw CloudError.authExpired }
            return value
        }
        let pass = try credential("passToken", fallback: previous?.passToken ?? cookies.cookies?.first(where: { $0.name == "passToken" })?.value)
        let cUser = try credential("cUserId", fallback: previous?.cUserId)
        return Session(userId: userId, ssecurity: security, serviceToken: token, region: region, cUserId: cUser, passToken: pass)
    }
    func refresh(_ session: Session) async throws -> Session {
        do {
            guard let pass = session.passToken, Self.validCredential(pass), Self.validCredential(session.userId) else { throw CloudError.authExpired }
            var components = URLComponents(string: "https://account.xiaomi.com/pass/serviceLogin")!
            components.queryItems = [URLQueryItem(name: "sid", value: "xiaomiio"), URLQueryItem(name: "_json", value: "true"), URLQueryItem(name: "_locale", value: "zh_CN")]
            var request = URLRequest(url: components.url!)
            var cookie = "userId=\(session.userId); passToken=\(pass)"
            if let id = session.cUserId, Self.validCredential(id) { cookie += "; cUserId=\(id)" }
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let (data, response) = try await http.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.authExpired }
            let object = try QRLogin.strip(data)
            guard let code = object["code"] as? Int, code == 0 else { throw CloudError.authExpired }
            return try await finish(object, region: session.region, previous: session)
        } catch { throw CloudError.authExpired }
    }
}
