import AppKit
import CryptoKit
import Foundation
import os

struct APICredentials: Codable, Equatable {
    var clientID = ""
    var clientSecret = ""
    var redirectURI = "cumulus://oauth/callback"

    var isComplete: Bool {
        !clientID.trimmed.isEmpty && !clientSecret.trimmed.isEmpty && callbackScheme != nil
    }
    var callbackScheme: String? { URL(string: redirectURI.trimmed)?.scheme?.nilIfEmpty }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

enum AuthError: LocalizedError {
    case missingCredentials, cancelled, couldNotStart, stateMismatch, noCode, notLoggedIn, sessionExpired
    case server(String)
    case token(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Add your SoundCloud app's client ID and secret first."
        case .cancelled: "Login was cancelled."
        case .couldNotStart: "Couldn't open the SoundCloud login window."
        case .stateMismatch: "Login response didn't match the request. Try again."
        case .noCode: "SoundCloud didn't return an authorization code."
        case .notLoggedIn: "You're not logged in."
        case .sessionExpired: "Your SoundCloud session expired. Log in again."
        case .server(let m): "SoundCloud refused the login: \(m)"
        case .token(let code, let body): "Token request failed (\(code)). \(body.prefix(160))"
        }
    }
}

/// OAuth 2.1 authorization-code flow with PKCE against secure.soundcloud.com,
/// completed in the user's default browser and returned to the app via the cumulus:// URL scheme.
@MainActor @Observable final class AuthManager {
    private(set) var isLoggedIn = false
    private(set) var isBusy = false
    private(set) var credentials: APICredentials
    /// True when the app key was baked into the bundle at build time: users only see "Log in".
    let hasBuiltInKey: Bool

    @ObservationIgnored private var tokens: OAuthTokens?
    @ObservationIgnored private var refreshTask: Task<Void, Error>?
    /// True while we wait for the user to approve in their default browser.
    private(set) var waitingForBrowser = false
    @ObservationIgnored private var pending: (state: String, cont: CheckedContinuation<URL, Error>)?
    @ObservationIgnored private var lastAuthorizeURL: URL?
    @ObservationIgnored var onSessionExpired: (() -> Void)?

    private static let authorizeURL = "https://secure.soundcloud.com/authorize"
    private static let tokenURL = URL(string: "https://secure.soundcloud.com/oauth/token")!

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let id = (info["SCClientID"] as? String)?.trimmed.nilIfEmpty,
           let secret = (info["SCClientSecret"] as? String)?.trimmed.nilIfEmpty {
            var built = APICredentials(clientID: id, clientSecret: secret)
            if let r = (info["SCRedirectURI"] as? String)?.trimmed.nilIfEmpty { built.redirectURI = r }
            hasBuiltInKey = true
            credentials = built
            tokens = Keychain.load(OAuthTokens.self, "tokens")
            isLoggedIn = tokens != nil
            return
        }
        hasBuiltInKey = false
        var c = Keychain.load(APICredentials.self, "credentials") ?? APICredentials()
        let env = ProcessInfo.processInfo.environment
        if c.clientID.isEmpty, let id = env["SC_CLIENT_ID"] { c.clientID = id }
        if c.clientSecret.isEmpty, let s = env["SC_CLIENT_SECRET"] { c.clientSecret = s }
        if let r = env["SC_REDIRECT_URI"] { c.redirectURI = r }
        credentials = c
        tokens = Keychain.load(OAuthTokens.self, "tokens")
        isLoggedIn = tokens != nil
    }

    func updateCredentials(_ c: APICredentials) {
        guard !hasBuiltInKey else { return }
        var c = c
        c.clientID = c.clientID.trimmed
        c.clientSecret = c.clientSecret.trimmed
        c.redirectURI = c.redirectURI.trimmed
        guard c != credentials else { return }
        credentials = c
        Keychain.save(c, "credentials")
    }

    // MARK: Login

    func login() async throws {
        let c = credentials
        guard c.isComplete, c.callbackScheme != nil else { throw AuthError.missingCredentials }
        isBusy = true
        defer { isBusy = false }

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)

        var comps = URLComponents(string: Self.authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id", value: c.clientID),
            .init(name: "redirect_uri", value: c.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]

        let callback = try await authorizeInBrowser(comps.url!, state: state)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }

        if let err = value("error") { throw AuthError.server(value("error_description") ?? err) }
        guard value("state") == state else { throw AuthError.stateMismatch }
        guard let code = value("code") else { throw AuthError.noCode }

        try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": c.clientID,
            "client_secret": c.clientSecret,
            "redirect_uri": c.redirectURI,
            "code_verifier": verifier,
            "code": code,
        ])
        isLoggedIn = true
    }

    /// Opens SoundCloud's authorize page in the user's normal default browser (already signed in there),
    /// then waits for the browser to hand `cumulus://oauth/callback?...` back to the app.
    private func authorizeInBrowser(_ url: URL, state: String) async throws -> URL {
        finishPending(.failure(AuthError.cancelled))
        return try await withCheckedThrowingContinuation { cont in
            pending = (state, cont)
            waitingForBrowser = true
            lastAuthorizeURL = url
            if !NSWorkspace.shared.open(url) { finishPending(.failure(AuthError.couldNotStart)) }
        }
    }

    /// Called for every URL the system opens with this app. Returns true if it was our OAuth callback.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let scheme = credentials.callbackScheme, url.scheme?.lowercased() == scheme.lowercased() else { return false }
        Logger(subsystem: "com.kareem.cumulus", category: "auth")
            .notice("OAuth callback received (login pending: \(self.pending != nil, privacy: .public))")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value
        guard let p = pending else { return true }
        // Ignore stale callbacks from an earlier attempt, unless SoundCloud reports an error.
        guard state == p.state || items.contains(where: { $0.name == "error" }) else { return true }
        finishPending(.success(url))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        return true
    }

    func cancelLogin() { finishPending(.failure(AuthError.cancelled)) }

    func reopenBrowser() {
        if let u = lastAuthorizeURL { NSWorkspace.shared.open(u) }
    }

    private func finishPending(_ r: Result<URL, Error>) {
        guard let p = pending else { return }
        pending = nil
        waitingForBrowser = false
        p.cont.resume(with: r)
    }

    // MARK: Tokens

    func validToken() async throws -> String {
        guard let t = tokens else { throw AuthError.notLoggedIn }
        if t.expiresAt.timeIntervalSinceNow > 60 { return t.accessToken }
        try await refresh()
        guard let fresh = tokens else { throw AuthError.notLoggedIn }
        return fresh.accessToken
    }

    /// Refresh tokens are single-use, so concurrent callers share one in-flight refresh.
    func refresh() async throws {
        if let running = refreshTask { return try await running.value }
        let task = Task { @MainActor in
            defer { self.refreshTask = nil }
            guard let rt = self.tokens?.refreshToken else {
                self.expire()
                throw AuthError.sessionExpired
            }
            let c = self.credentials
            do {
                try await self.tokenRequest([
                    "grant_type": "refresh_token",
                    "client_id": c.clientID,
                    "client_secret": c.clientSecret,
                    "refresh_token": rt,
                ])
            } catch AuthError.token(let code, _) where code == 400 || code == 401 {
                self.expire()
                throw AuthError.sessionExpired
            }
        }
        refreshTask = task
        try await task.value
    }

    private func tokenRequest(_ params: [String: String]) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        req.httpBody = params.map { "\($0.key)=\($0.value.formEncoded)" }
            .joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AuthError.token(status, String(data: data, encoding: .utf8) ?? "")
        }
        struct R: Decodable { let accessToken: String; let refreshToken: String?; let expiresIn: Double? }
        let r = try JSON.decoder.decode(R.self, from: data)
        let t = OAuthTokens(
            accessToken: r.accessToken,
            refreshToken: r.refreshToken ?? tokens?.refreshToken,
            expiresAt: Date().addingTimeInterval(r.expiresIn ?? 3600)
        )
        tokens = t
        Keychain.save(t, "tokens")
    }

    func logout() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        Keychain.delete("tokens")
        isLoggedIn = false
    }

    private func expire() {
        logout()
        onSessionExpired?()
    }

    // MARK: Utils

    static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var formEncoded: String { addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? self }
}
