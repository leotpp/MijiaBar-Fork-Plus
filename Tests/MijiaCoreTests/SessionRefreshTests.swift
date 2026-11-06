import Foundation
import Testing
@testable import MijiaCore

private func fixture(_ fresh: Bool = false, region: String = "cn") -> Session {
    Session(userId: "synthetic-user", ssecurity: Data(repeating: fresh ? 2 : 1, count: 16).base64EncodedString(),
            serviceToken: fresh ? "synthetic-new" : "synthetic-old", region: region, passToken: "synthetic-pass")
}
private final class RefreshState: @unchecked Sendable {
    let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; values[name, default: 0] += 1; return values[name]! }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[name, default: 0] }
}
private actor RefreshGate {
    var started = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    var release: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; waiting.forEach { $0.resume() }; waiting = []
        await withCheckedContinuation { release = $0 }
    }
    func entered() async { if !started { await withCheckedContinuation { waiting.append($0) } } }
    func open() { release?.resume(); release = nil }
}
private final class RefreshProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var delay: RefreshGate?
    static func use(_ value: Handler?, delay: RefreshGate? = nil) { lock.lock(); defer { lock.unlock() }; handler = value; self.delay = delay }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler, delay = Self.delay; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let (status, body, headers) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            let deliver: @Sendable () -> Void = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
            }
            if let delay, request.url?.path == "/app/held" { Task { await delay.pause(); deliver() } }
            else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    }
    override func stopLoading() {}
}
private func configuration() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [RefreshProtocol.self]; return c
}
private func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func expired(_ operation: () async throws -> Void) async -> Bool {
    do { try await operation(); return false } catch CloudError.authExpired { return true } catch { return false }
}

@Suite(.serialized) struct SessionRefreshTests {
    @Test(arguments: [401, 403, 426, 2, 3, 200, 429, 500, 427])
    func authenticationTriggers(_ code: Int) async throws {
        let state = RefreshState()
        RefreshProtocol.use { request in
            let attempt = state.increment("api")
            if attempt > 1 || code == 200 { return (200, json(["code": 0, "result": true]), [:]) }
            if code == 2 || code == 3 { return (200, json(["code": code]), [:]) }
            return (code == 427 ? 426 : code, json(["message": code == 426 ? "SERVICETOKEN_EXPIRED" : "other"]), [:])
        }
        defer { RefreshProtocol.use(nil) }
        let http = URLSession(configuration: configuration()); defer { http.invalidateAndCancel() }
        let cloud = XiaomiCloud(session: fixture(), http: http, refresh: { _ in _ = state.increment("refresh"); return fixture(true) }, commit: { $0 })
        do { _ = try await cloud.call("/test", [:]) } catch { }
        let expected = [401, 403, 426, 2, 3].contains(code) ? 1 : 0
        #expect(state.count("refresh") == expected)
        #expect(state.count("api") == expected + 1)
    }

    @Test func concurrentCallsShareRecoveryAndTransportErrorsDoNotRefresh() async throws {
        let state = RefreshState(), gate = RefreshGate()
        RefreshProtocol.use { request in
            if request.url?.path == "/app/network" { throw URLError(.timedOut) }
            let fresh = request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-new") == true
            return fresh ? (200, json(["code": 0, "result": true]), [:]) : (401, Data(), [:])
        }
        defer { RefreshProtocol.use(nil) }
        let http = URLSession(configuration: configuration()); defer { http.invalidateAndCancel() }
        let cloud = XiaomiCloud(session: fixture(), http: http, refresh: { _ in
            _ = state.increment("refresh"); await gate.pause(); return fixture(true)
        }, commit: { value in _ = state.increment("commit"); return value })
        do { _ = try await cloud.call("/network", [:]); Issue.record("Transport error was lost") } catch is URLError { }
        #expect(state.count("refresh") == 0)
        let callers = (0..<20).map { _ in Task { try await cloud.call("/test", [:]) as? Bool == true } }
        await gate.entered(); await gate.open()
        for caller in callers { #expect(try await caller.value) }
        #expect(state.count("refresh") == 1); #expect(state.count("commit") == 1)
    }

    @Test func singleFlightLateRejectionAndCancellation() async throws {
        let state = RefreshState(), gate = RefreshGate()
        let keeper = SessionKeeper(session: fixture(), refresh: { _ in
            _ = state.increment("refresh"); await gate.pause(); return fixture(true)
        }, commit: { value in _ = state.increment("commit"); return value })
        let first = Task { try await keeper.recover(rejectedGeneration: 0) }
        await gate.entered()
        let cancelled = Task { try await keeper.recover(rejectedGeneration: 0) }
        cancelled.cancel()
        let others = (0..<20).map { _ in Task { try await keeper.recover(rejectedGeneration: 0) } }
        await gate.open()
        _ = try await first.value
        for other in others { let value = try await other.value; #expect(value.generation == 1) }
        do { _ = try await cancelled.value; Issue.record("Cancelled waiter succeeded") } catch is CancellationError { }
        let late = try await keeper.recover(rejectedGeneration: 0)
        #expect(late.generation == 1)
        #expect(state.count("refresh") == 1); #expect(state.count("commit") == 1)
    }

    @Test(arguments: [false, true]) func failureCooldownAndClock(_ persistenceFails: Bool) async throws {
        let state = RefreshState()
        let keeper = SessionKeeper(session: fixture(), refresh: { _ in
            _ = state.increment("refresh")
            if !persistenceFails { throw URLError(.timedOut) }; return fixture(true)
        }, commit: { _ in throw CloudError.badResponse }, clock: { Date(timeIntervalSince1970: Double(state.count("clock"))) })
        #expect(await expired { _ = try await keeper.recover(rejectedGeneration: 0) })
        #expect(await expired { _ = try await keeper.snapshot() })
        #expect(await expired { _ = try await keeper.recover(rejectedGeneration: 0) })
        #expect(state.count("refresh") == 1)
        for _ in 0..<60 { _ = state.increment("clock") }
        #expect(await expired { _ = try await keeper.recover(rejectedGeneration: 0) })
        #expect(state.count("refresh") == 2)
    }

    @Test func invalidationPreventsCommit() async throws {
        let state = RefreshState(), gate = RefreshGate()
        let keeper = SessionKeeper(session: fixture(), refresh: { _ in await gate.pause(); return fixture(true) },
                                   commit: { value in _ = state.increment("commit"); return value })
        let flight = Task { await expired { _ = try await keeper.recover(rejectedGeneration: 0) } }
        await gate.entered(); keeper.invalidate(); await gate.open()
        #expect(await flight.value); #expect(state.count("commit") == 0)
        #expect(await expired { _ = try await keeper.snapshot() })
    }

    @Test func replayStopsAndCoolsDown() async throws {
        let state = RefreshState()
        RefreshProtocol.use { _ in _ = state.increment("api"); return (401, Data(), [:]) }
        defer { RefreshProtocol.use(nil) }
        let http = URLSession(configuration: configuration()); defer { http.invalidateAndCancel() }
        let cloud = XiaomiCloud(session: fixture(), http: http, refresh: { _ in _ = state.increment("refresh"); return fixture(true) }, commit: { $0 })
        for _ in 0..<4 { #expect(await expired { _ = try await cloud.call("/test", [:]) }) }
        #expect(state.count("api") == 2); #expect(state.count("refresh") == 1)
    }

    @Test(arguments: ["cn", "de"]) func refreshSignsAndDecryptsUsingAttemptSnapshot(_ region: String) async throws {
        let state = RefreshState()
        RefreshProtocol.use { request in
            let fresh = state.increment("api") > 1
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let security = items.first { $0.name == "ssecurity" }!.value!
            let nonce = items.first { $0.name == "_nonce" }!.value!
            let matches = security == fixture(fresh, region: region).ssecurity
            #expect(matches)
            #expect(request.url?.host == (region == "cn" ? "api.io.mi.com" : "de.api.io.mi.com"))
            let cookieMatches = request.value(forHTTPHeaderField: "Cookie")?.contains(fixture(fresh).serviceToken) == true
            #expect(cookieMatches)
            if !fresh { return (426, json(["message": "SERVICETOKEN_EXPIRED"]), [:]) }
            let key = Data(base64Encoded: MiCrypto.signedNonce(ssecurity: security, nonce: nonce))!
            return (200, Data(MiCrypto.rc4(key: key, json(["code": 0, "result": true])).base64EncodedString().utf8), [:])
        }
        defer { RefreshProtocol.use(nil) }
        let http = URLSession(configuration: configuration()); defer { http.invalidateAndCancel() }
        let cloud = XiaomiCloud(session: fixture(region: region), http: http, refresh: { _ in fixture(true, region: region) }, commit: { $0 })
        let succeeded = try await cloud.call("/test", [:]) as? Bool == true
        #expect(succeeded); #expect(state.count("api") == 2)
    }

    @Test(arguments: ["success", "missingPass", "emptyPass", "denied", "malformed", "missingCookie", "wrongDomain", "network", "badLocation", "badSecurity", "badUser"])
    func accountFlow(_ mode: String) async throws {
        let state = RefreshState()
        let login = AccountLogin(configuration: configuration())
        RefreshProtocol.use { request in
            if request.url?.host == "account.xiaomi.com" {
                _ = state.increment("login")
                if mode == "network" { throw URLError(.timedOut) }
                if mode == "malformed" { return (200, Data("invalid".utf8), [:]) }
                return (200, json(["code": mode == "denied" ? 1 : 0, "userId": mode == "badUser" ? "other" : "synthetic-user",
                                   "ssecurity": mode == "badSecurity" ? "!" : fixture(true).ssecurity,
                                   "location": mode == "badLocation" ? "https://invalid.example/sts" : "https://sts.api.io.mi.com/sts",
                                   "passToken": "synthetic-rotated", "cUserId": "synthetic-cuser"]), [:])
            }
            _ = state.increment("sts")
            if mode != "missingCookie" {
                let domain = mode == "wrongDomain" ? "invalid.example" : "sts.api.io.mi.com"
                let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "serviceToken", .value: "synthetic-new", .secure: "TRUE"])!
                login.cookies.setCookie(cookie)
            }
            return (200, Data(), [:])
        }
        defer { RefreshProtocol.use(nil); login.http.invalidateAndCancel() }
        var old = fixture(region: "de")
        if mode == "missingPass" { old.passToken = nil }
        if mode == "emptyPass" { old.passToken = "" }
        if mode == "success" {
            let value = try await login.refresh(old)
            let rotated = value.passToken == "synthetic-rotated" && value.cUserId == "synthetic-cuser" && value.serviceToken == "synthetic-new"
            #expect(rotated); #expect(value.region == "de")
        } else { #expect(await expired { _ = try await login.refresh(old) }) }
        if mode == "missingPass" || mode == "emptyPass" { #expect(state.count("login") == 0) }
    }

    @Test(arguments: ["same", "missing", "account", "region"]) func persistenceIdentityGuard(_ mode: String) throws {
        var current = fixture()
        if mode == "account" { current.userId = "other" }
        if mode == "region" { current.region = "de" }
        var wrote = false
        let result = try Session.persistRefresh(fixture(true), load: { mode == "missing" ? nil : current }, save: { _ in wrote = true })
        #expect(wrote == (mode == "same" || mode == "missing"))
        let adopted = wrote || (result.userId == current.userId && result.region == current.region)
        #expect(adopted)
    }

    @Test func oldResponseDecryptsAfterFullAccountRefresh() async throws {
        let state = RefreshState(), gate = RefreshGate()
        let login = AccountLogin(configuration: configuration())
        RefreshProtocol.use({ request in
            let url = request.url!
            if url.host == "account.xiaomi.com" {
                _ = state.increment("login")
                return (200, json(["code": 0, "userId": "synthetic-user", "ssecurity": fixture(true).ssecurity,
                                   "location": "https://sts.api.io.mi.com/sts"]), [:])
            }
            if url.host == "sts.api.io.mi.com" {
                _ = state.increment("sts")
                login.cookies.setCookie(HTTPCookie(properties: [.domain: "sts.api.io.mi.com", .path: "/", .name: "serviceToken", .value: "synthetic-new"])!)
                return (200, Data(), [:])
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let security = items.first { $0.name == "ssecurity" }!.value!
            let nonce = items.first { $0.name == "_nonce" }!.value!
            if url.path != "/app/held", security == fixture().ssecurity { return (426, json(["message": "SERVICETOKEN_EXPIRED"]), [:]) }
            let key = Data(base64Encoded: MiCrypto.signedNonce(ssecurity: security, nonce: nonce))!
            return (200, Data(MiCrypto.rc4(key: key, json(["code": 0, "result": true])).base64EncodedString().utf8), [:])
        }, delay: gate)
        defer { RefreshProtocol.use(nil); login.http.invalidateAndCancel() }
        let http = URLSession(configuration: configuration()); defer { http.invalidateAndCancel() }
        let cloud = XiaomiCloud(session: fixture(), http: http, refresh: { try await login.refresh($0) }, commit: { value in _ = state.increment("commit"); return value })
        let held = Task { try await cloud.call("/held", [:]) as? Bool == true }
        await gate.entered()
        let replayed = try await cloud.call("/trigger", [:]) as? Bool == true
        await gate.open()
        #expect(try await held.value); #expect(replayed)
        #expect(state.count("login") == 1); #expect(state.count("sts") == 1); #expect(state.count("commit") == 1)
    }

    @Test func cookieJarsAreIsolatedAndOldCookieIsRejected() async throws {
        let one = AccountLogin(configuration: configuration()), two = AccountLogin(configuration: configuration())
        defer { one.http.invalidateAndCancel(); two.http.invalidateAndCancel(); RefreshProtocol.use(nil) }
        let cookie = HTTPCookie(properties: [.domain: "sts.api.io.mi.com", .path: "/", .name: "serviceToken", .value: "synthetic-old"])!
        one.cookies.setCookie(cookie)
        let isolated = !(two.cookies.cookies ?? []).contains { $0.name == "serviceToken" }
        #expect(isolated)
        RefreshProtocol.use { _ in (200, Data(), [:]) }
        #expect(await expired { _ = try await one.finish(["userId": "synthetic-user", "ssecurity": fixture().ssecurity,
                                                         "location": "https://sts.api.io.mi.com/sts"], region: "cn") })
    }
}
