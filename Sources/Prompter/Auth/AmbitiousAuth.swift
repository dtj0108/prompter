import AppKit
import AuthenticationServices
import Combine
import Foundation

private struct AmbitiousAuthConfiguration {
    let issuer: URL
    let clientID: String
    let redirectURI: URL
    /// Branded front door for the authorization request. Release sign-in opens
    /// this www.ambitious.social URL — which forwards the exact query to the
    /// hosted authorize endpoint — so every surface the user sees (the macOS
    /// confirmation sheet, the browser popup and address bar) names Ambitious,
    /// never the Supabase issuer host. nil (the DEBUG lab has no branded front
    /// door) opens the authorize endpoint from discovery directly.
    let brandedAuthorizationStart: URL?

    static var current: AmbitiousAuthConfiguration {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let issuerValue = environment["PROMPTER_AMBITIOUS_ISSUER"],
           let clientID = environment["PROMPTER_AMBITIOUS_CLIENT_ID"],
           !clientID.isEmpty,
           let issuer = URL(string: issuerValue),
           let redirect = URL(string: environment["PROMPTER_AMBITIOUS_REDIRECT_URI"] ?? "prompter-lab://oauth/callback"),
           ["127.0.0.1", "localhost"].contains(issuer.host ?? ""),
           redirect.scheme == "prompter-lab" {
            return AmbitiousAuthConfiguration(
                issuer: issuer,
                clientID: clientID,
                redirectURI: redirect,
                brandedAuthorizationStart: nil
            )
        }
#endif
        return AmbitiousAuthConfiguration(
            issuer: URL(string: "https://ehplhuzlsxrhhpkqxeyc.supabase.co/auth/v1")!,
            clientID: "6f2eb6a1-e2b8-470f-a35d-0df05fbdd717",
            redirectURI: URL(string: "https://www.ambitious.social/oauth/prompter/callback")!,
            brandedAuthorizationStart: URL(string: "https://www.ambitious.social/oauth/prompter/start")!
        )
    }

    var isActivated: Bool { !clientID.isEmpty }

    func callback() -> ASWebAuthenticationSession.Callback {
#if DEBUG
        if redirectURI.scheme == "prompter-lab" {
            return .customScheme("prompter-lab")
        }
#endif
        return .https(host: "www.ambitious.social", path: "/oauth/prompter/callback")
    }

    func allowsEndpoint(_ url: URL) -> Bool {
#if DEBUG
        return AmbitiousOIDCEndpointPolicy.allows(
            url,
            issuer: issuer,
            allowLoopbackHTTP: true
        )
#else
        return AmbitiousOIDCEndpointPolicy.allows(url, issuer: issuer)
#endif
    }
}

private struct AmbitiousDiscovery: Decodable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let userInfoEndpoint: URL
    let jwksURI: URL
    let responseTypesSupported: [String]
    let codeChallengeMethodsSupported: [String]
    let idTokenSigningAlgValuesSupported: [String]

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case userInfoEndpoint = "userinfo_endpoint"
        case jwksURI = "jwks_uri"
        case responseTypesSupported = "response_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
    }
}

private struct AmbitiousTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Double

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private struct AmbitiousOAuthErrorResponse: Decodable {
    let error: String?
    let errorCode: String?

    var code: String? { error ?? errorCode }

    private enum CodingKeys: String, CodingKey {
        case error
        case errorCode = "error_code"
    }
}

private struct AmbitiousUserInfo: Decodable {
    let sub: String
    let email: String?
    let emailVerified: Bool?

    private enum CodingKeys: String, CodingKey {
        case sub, email
        case emailVerified = "email_verified"
    }
}

private struct AmbitiousLoginTransaction {
    let state: String
    let nonce: String
    let verifier: String
}

private enum AmbitiousAuthFlowError: Error {
    case notActivated
    case invalidDiscovery
    case browserCouldNotStart
    case canceled
    case denied
    case invalidCallback
    case network
    case tokenEndpoint(status: Int, code: String?)
    case invalidToken
    case invalidUserInfo
    case keychain
}

private enum AmbitiousRefreshResult {
    case success(AmbitiousStoredSession)
    case transientFailure
    case definitiveRevocation
}

private enum AmbitiousPendingSignOutReason: Equatable {
    case user
    case revoked
}

#if DEBUG
/// The local lab uses a custom callback scheme, so opening the ordinary system
/// browser makes the flow observable and reproducible without weakening the
/// release build's verified-HTTPS ASWebAuthenticationSession boundary.
@MainActor
final class AmbitiousDebugCallbackBroker {
    static let shared = AmbitiousDebugCallbackBroker()

    private var continuation: CheckedContinuation<URL, Error>?

    private init() {}

    func open(_ authorizationURL: URL) async throws -> URL {
        guard continuation == nil else {
            throw AmbitiousAuthFlowError.browserCouldNotStart
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard NSWorkspace.shared.open(authorizationURL) else {
                self.continuation = nil
                continuation.resume(throwing: AmbitiousAuthFlowError.browserCouldNotStart)
                return
            }
        }
    }

    @discardableResult
    func handle(_ callbackURL: URL) -> Bool {
        guard callbackURL.scheme == "prompter-lab", let continuation else {
            return false
        }
        self.continuation = nil
        continuation.resume(returning: callbackURL)
        return true
    }

    /// An abandoned lab browser never delivers a callback; user-driven cancel
    /// resolves the waiting flow the same way the release session cancel does.
    func cancelPending() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: AmbitiousAuthFlowError.canceled)
    }
}
#endif

enum AmbitiousAuthActivity: Equatable {
    case idle
    case signingIn
    case refreshing
    case signOutPending
}

/// Owns the browser flow and refresh policy. Identity remains available
/// indefinitely while offline; refresh is a background account-health check,
/// never part of recording, transcription, or paste.
final class AmbitiousAuthManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = AmbitiousAuthManager()
    static let refreshCadence: TimeInterval = 24 * 60 * 60

    @Published private(set) var identity: AmbitiousIdentity?
    @Published private(set) var activity: AmbitiousAuthActivity = .idle
    @Published private(set) var errorMessage: String?

    var isSignedIn: Bool { identity != nil }
    var isActivated: Bool { AmbitiousAuthConfiguration.current.isActivated }

    private var webSession: ASWebAuthenticationSession?
    private var refreshTimer: Timer?
    private var refreshRunning = false
    private var pendingSignOutReason: AmbitiousPendingSignOutReason?
    private let fallbackAnchor = NSWindow()
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private override init() {
        identity = Self.usableStoredSession()?.identity
        super.init()
    }

    static func hasUsableCachedIdentity() -> Bool {
        usableStoredSession() != nil
    }

    private static func usableStoredSession() -> AmbitiousStoredSession? {
        let configuration = AmbitiousAuthConfiguration.current
        guard configuration.isActivated,
              let session = try? AmbitiousKeychainStore.loadSession(),
              session.clientID == configuration.clientID,
              session.identity.issuer == configuration.issuer.absoluteString else { return nil }
        return session
    }

    func startBackgroundRefreshSchedule() {
        refreshIfDue()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.refreshIfDue()
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
    }

    func signIn() {
        guard identity == nil, activity != .signingIn else { return }
        let configuration = AmbitiousAuthConfiguration.current
        guard configuration.isActivated else {
            errorMessage = "Ambitious sign-in is waiting for production activation."
            return
        }
        activity = .signingIn
        errorMessage = nil
        Task {
            do {
                let session = try await performSignIn(configuration: configuration)
                do {
                    try AmbitiousKeychainStore.saveSession(session)
                } catch {
                    throw AmbitiousAuthFlowError.keychain
                }
                await MainActor.run {
                    self.identity = session.identity
                    self.activity = .idle
                    self.errorMessage = nil
                    // The browser flow leaves Chrome/Safari frontmost; put the
                    // assistant back in front so setup visibly continues.
                    WindowRouter.shared.focusOnboarding()
                }
                Log.write("Ambitious sign-in completed")
            } catch AmbitiousAuthFlowError.canceled, AmbitiousAuthFlowError.denied {
                await MainActor.run {
                    self.activity = .idle
                    self.errorMessage = nil
                }
                Log.write("Ambitious sign-in canceled")
            } catch AmbitiousAuthFlowError.notActivated {
                await MainActor.run {
                    self.activity = .idle
                    self.errorMessage = "Ambitious sign-in is waiting for production activation."
                }
            } catch {
                await MainActor.run {
                    self.activity = .idle
                    self.errorMessage = self.userFacingMessage(for: error)
                }
                Log.write("Ambitious sign-in failed after a network or protocol check")
            }
        }
    }

    /// User-requested sign-out also waits for an active recording/transcription
    /// to finish so auth state can never discard the words already captured.
    func signOut() {
        guard identity != nil else { return }
        if DictationController.shared.hasInFlightDictation {
            pendingSignOutReason = .user
            activity = .signOutPending
            errorMessage = "Finishing the current dictation before signing out."
            return
        }
        completeSignOut(message: nil)
    }

    /// Cancels an in-flight browser sign-in. A closed browser tab never calls
    /// back, so without this the gate screen would wait in "Signing in…"
    /// forever; cancelling resumes the flow through the normal canceled path.
    func cancelSignIn() {
        DispatchQueue.main.async {
            self.webSession?.cancel()
#if DEBUG
            MainActor.assumeIsolated {
                AmbitiousDebugCallbackBroker.shared.cancelPending()
            }
#endif
        }
    }

    func refreshNow() {
        refresh(force: true)
    }

#if DEBUG
    /// Synchronous acceptance hook for the disposable local OAuth lab. Public
    /// builds never include this entry point.
    func refreshNowForTesting() async -> Bool {
        let configuration = AmbitiousAuthConfiguration.current
        guard configuration.isActivated,
              let session = Self.usableStoredSession() else { return false }
        let result = await performRefresh(session: session, configuration: configuration)
        await MainActor.run {
            self.handleRefreshResult(result)
        }
        return await MainActor.run { self.isSignedIn }
    }
#endif

    func dictationDidBecomeIdle() {
        guard let reason = pendingSignOutReason,
              !DictationController.shared.hasInFlightDictation else { return }
        let message = reason == .revoked
            ? "Your Ambitious authorization ended. Sign in again to keep using Ambitious Prompts."
            : nil
        completeSignOut(message: message)
    }

    private func refreshIfDue() {
        guard let session = Self.usableStoredSession(),
              Date().timeIntervalSince(session.lastSuccessfulRefreshAt) >= Self.refreshCadence else { return }
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        guard !refreshRunning,
              let session = Self.usableStoredSession() else { return }
        if !force, Date().timeIntervalSince(session.lastSuccessfulRefreshAt) < Self.refreshCadence { return }
        let configuration = AmbitiousAuthConfiguration.current
        guard configuration.isActivated else { return }
        refreshRunning = true
        activity = .refreshing
        errorMessage = nil
        Task {
            let result = await performRefresh(session: session, configuration: configuration)
            await MainActor.run {
                self.refreshRunning = false
                self.handleRefreshResult(result)
            }
        }
    }

    private func handleRefreshResult(_ result: AmbitiousRefreshResult) {
        guard identity != nil else {
            activity = .idle
            return
        }
        if pendingSignOutReason == .user { return }
        switch result {
        case .success(let updated):
            guard identity != nil, pendingSignOutReason == nil else { return }
            do {
                try AmbitiousKeychainStore.saveSession(updated)
                identity = updated.identity
                activity = .idle
                errorMessage = nil
                Log.write("Ambitious account refresh completed")
            } catch {
                activity = .idle
                errorMessage = "Account check couldn't be saved. Ambitious Prompts still works offline."
                Log.write("Ambitious account refresh storage failed")
            }
        case .transientFailure:
            guard identity != nil, pendingSignOutReason == nil else { return }
            activity = .idle
            errorMessage = "Couldn't check the account right now. Ambitious Prompts still works offline."
            Log.write("Ambitious account refresh deferred after a transient failure")
        case .definitiveRevocation:
            let decision = AmbitiousAuthGate.decision(
                hasCachedIdentity: identity != nil,
                refreshOutcome: .definitiveRevocation,
                dictationInFlight: DictationController.shared.hasInFlightDictation
            )
            if decision == .deferSignOut {
                pendingSignOutReason = .revoked
                activity = .signOutPending
                errorMessage = "Your authorization ended. Finishing the current dictation first."
            } else {
                completeSignOut(message: "Your Ambitious authorization ended. Sign in again to keep using Ambitious Prompts.")
            }
            Log.write("Ambitious grant was revoked")
        }
    }

    private func completeSignOut(message: String?) {
        do {
            try AmbitiousKeychainStore.deleteSession()
        } catch {
            Log.write("Ambitious Keychain item could not be deleted")
        }
        pendingSignOutReason = nil
        identity = nil
        activity = .idle
        errorMessage = message
        // Signed out means no app access: retire the main window and put the
        // Ambitious sign-in screen up in its place.
        WindowRouter.shared.closeMain()
        WindowRouter.shared.openOnboarding(startStep: .signIn)
    }

    private func performSignIn(configuration: AmbitiousAuthConfiguration) async throws -> AmbitiousStoredSession {
        guard configuration.isActivated else { throw AmbitiousAuthFlowError.notActivated }
        let discovery = try await fetchDiscovery(configuration: configuration)
        let transaction = AmbitiousLoginTransaction(
            state: try AmbitiousPKCE.verifier(),
            nonce: try AmbitiousPKCE.verifier(),
            verifier: try AmbitiousPKCE.verifier()
        )
        guard let authorizationURL = AmbitiousAuthorizationEntry.url(
            brandedStart: configuration.brandedAuthorizationStart,
            authorizationEndpoint: discovery.authorizationEndpoint,
            queryItems: [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "openid email"),
                URLQueryItem(name: "state", value: transaction.state),
                URLQueryItem(name: "nonce", value: transaction.nonce),
                URLQueryItem(name: "code_challenge", value: AmbitiousPKCE.challenge(for: transaction.verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
        ) else { throw AmbitiousAuthFlowError.invalidDiscovery }
        let callbackURL = try await openBrowser(
            authorizationURL: authorizationURL,
            callback: configuration.callback(),
            usesDebugCustomScheme: configuration.redirectURI.scheme == "prompter-lab"
        )
        let code = try validateCallback(
            callbackURL,
            expectedRedirect: configuration.redirectURI,
            transaction: transaction
        )
        let tokenResponse = try await requestToken(
            endpoint: discovery.tokenEndpoint,
            form: [
                "grant_type": "authorization_code",
                "client_id": configuration.clientID,
                "redirect_uri": configuration.redirectURI.absoluteString,
                "code": code,
                "code_verifier": transaction.verifier,
            ]
        )
        guard let idToken = tokenResponse.idToken,
              let refreshToken = tokenResponse.refreshToken,
              !refreshToken.isEmpty,
              !tokenResponse.accessToken.isEmpty,
              tokenResponse.expiresIn > 0 else {
            throw AmbitiousAuthFlowError.invalidToken
        }
        let jwks = try await fetchJWKS(discovery: discovery)
        let claims: AmbitiousIDTokenClaims
        do {
            claims = try AmbitiousJWTValidator.validate(
                idToken,
                jwks: jwks,
                issuer: configuration.issuer.absoluteString,
                clientID: configuration.clientID,
                nonce: transaction.nonce
            )
        } catch {
            throw AmbitiousAuthFlowError.invalidToken
        }
        let userInfo = try await fetchUserInfo(discovery: discovery, accessToken: tokenResponse.accessToken)
        guard userInfo.sub == claims.subject else { throw AmbitiousAuthFlowError.invalidUserInfo }
        let now = Date()
        return AmbitiousStoredSession(
            clientID: configuration.clientID,
            identity: AmbitiousIdentity(
                issuer: claims.issuer,
                subject: claims.subject,
                email: userInfo.email ?? claims.email,
                emailVerified: userInfo.emailVerified ?? claims.emailVerified
            ),
            accessToken: tokenResponse.accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accessTokenExpiresAt: now.addingTimeInterval(tokenResponse.expiresIn),
            lastSuccessfulRefreshAt: now
        )
    }

    private func performRefresh(
        session: AmbitiousStoredSession,
        configuration: AmbitiousAuthConfiguration
    ) async -> AmbitiousRefreshResult {
        do {
            let discovery = try await fetchDiscovery(configuration: configuration)
            let response = try await requestToken(
                endpoint: discovery.tokenEndpoint,
                form: [
                    "grant_type": "refresh_token",
                    "client_id": configuration.clientID,
                    "refresh_token": session.refreshToken,
                ]
            )
            guard !response.accessToken.isEmpty, response.expiresIn > 0 else { return .transientFailure }
            var updated = session
            updated.accessToken = response.accessToken
            updated.refreshToken = response.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? session.refreshToken
            updated.accessTokenExpiresAt = Date().addingTimeInterval(response.expiresIn)
            updated.lastSuccessfulRefreshAt = Date()

            if let idToken = response.idToken {
                let jwks = try await fetchJWKS(discovery: discovery)
                let claims = try AmbitiousJWTValidator.validate(
                    idToken,
                    jwks: jwks,
                    issuer: configuration.issuer.absoluteString,
                    clientID: configuration.clientID,
                    nonce: nil
                )
                guard claims.subject == session.identity.subject,
                      claims.issuer == session.identity.issuer else { return .transientFailure }
                let userInfo = try await fetchUserInfo(discovery: discovery, accessToken: response.accessToken)
                guard userInfo.sub == claims.subject else { return .transientFailure }
                updated.idToken = idToken
                updated.identity = AmbitiousIdentity(
                    issuer: claims.issuer,
                    subject: claims.subject,
                    email: userInfo.email ?? claims.email,
                    emailVerified: userInfo.emailVerified ?? claims.emailVerified
                )
            }
            return .success(updated)
        } catch AmbitiousAuthFlowError.tokenEndpoint(let status, let code) {
            // Deliberately narrow: invalid_client, other 4xx, 5xx, malformed
            // responses, validation errors, timeouts, and offline failures all
            // preserve cached access. Only the two exact HTTP 400 token-family
            // revocation codes mean the user's grant is definitively gone.
            return AmbitiousRefreshFailureClassifier.outcome(httpStatus: status, oauthError: code) == .definitiveRevocation
                ? .definitiveRevocation
                : .transientFailure
        } catch {
            return .transientFailure
        }
    }

    private func fetchDiscovery(configuration: AmbitiousAuthConfiguration) async throws -> AmbitiousDiscovery {
        let url = configuration.issuer.appendingPathComponent(".well-known/openid-configuration")
        let discovery: AmbitiousDiscovery = try await getJSON(url)
        guard discovery.issuer == configuration.issuer.absoluteString,
              configuration.allowsEndpoint(discovery.authorizationEndpoint),
              configuration.allowsEndpoint(discovery.tokenEndpoint),
              configuration.allowsEndpoint(discovery.userInfoEndpoint),
              configuration.allowsEndpoint(discovery.jwksURI),
              discovery.responseTypesSupported.contains("code"),
              discovery.codeChallengeMethodsSupported.contains("S256"),
              discovery.idTokenSigningAlgValuesSupported.contains("ES256") else {
            throw AmbitiousAuthFlowError.invalidDiscovery
        }
        return discovery
    }

    private func fetchJWKS(discovery: AmbitiousDiscovery) async throws -> AmbitiousJWKSet {
        try await getJSON(discovery.jwksURI)
    }

    private func fetchUserInfo(discovery: AmbitiousDiscovery, accessToken: String) async throws -> AmbitiousUserInfo {
        var request = URLRequest(url: discovery.userInfoEndpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let value = try? JSONDecoder().decode(AmbitiousUserInfo.self, from: data) else {
                throw AmbitiousAuthFlowError.invalidUserInfo
            }
            return value
        } catch let error as AmbitiousAuthFlowError {
            throw error
        } catch {
            throw AmbitiousAuthFlowError.network
        }
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let value = try? JSONDecoder().decode(T.self, from: data) else {
                throw AmbitiousAuthFlowError.network
            }
            return value
        } catch let error as AmbitiousAuthFlowError {
            throw error
        } catch {
            throw AmbitiousAuthFlowError.network
        }
    }

    private func requestToken(endpoint: URL, form: [String: String]) async throws -> AmbitiousTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AmbitiousAuthFlowError.network }
            guard (200..<300).contains(http.statusCode) else {
                let code = (try? JSONDecoder().decode(AmbitiousOAuthErrorResponse.self, from: data))?.code
                throw AmbitiousAuthFlowError.tokenEndpoint(status: http.statusCode, code: code)
            }
            guard let token = try? JSONDecoder().decode(AmbitiousTokenResponse.self, from: data) else {
                throw AmbitiousAuthFlowError.invalidToken
            }
            return token
        } catch let error as AmbitiousAuthFlowError {
            throw error
        } catch {
            throw AmbitiousAuthFlowError.network
        }
    }

    private func openBrowser(
        authorizationURL: URL,
        callback: ASWebAuthenticationSession.Callback,
        usesDebugCustomScheme: Bool
    ) async throws -> URL {
#if DEBUG
        if usesDebugCustomScheme {
            return try await AmbitiousDebugCallbackBroker.shared.open(authorizationURL)
        }
#endif
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(url: authorizationURL, callback: callback) { [weak self] url, error in
                    self?.webSession = nil
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: AmbitiousAuthFlowError.canceled)
                    } else if error != nil {
                        continuation.resume(throwing: AmbitiousAuthFlowError.network)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: AmbitiousAuthFlowError.invalidCallback)
                    }
                }
                session.presentationContextProvider = self
                self.webSession = session
                guard session.start() else {
                    self.webSession = nil
                    continuation.resume(throwing: AmbitiousAuthFlowError.browserCouldNotStart)
                    return
                }
            }
        }
    }

    private func validateCallback(
        _ url: URL,
        expectedRedirect: URL,
        transaction: AmbitiousLoginTransaction
    ) throws -> String {
        guard url.scheme == expectedRedirect.scheme,
              url.host == expectedRedirect.host,
              url.port == expectedRedirect.port,
              url.path == expectedRedirect.path,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.filter({ $0.name == "access_token" || $0.name == "id_token" || $0.name == "refresh_token" }).isEmpty,
              let returnedState = singleValue(named: "state", in: items),
              constantTimeEqual(returnedState, transaction.state) else {
            throw AmbitiousAuthFlowError.invalidCallback
        }
        if let error = singleValue(named: "error", in: items) {
            if error == "access_denied" { throw AmbitiousAuthFlowError.denied }
            throw AmbitiousAuthFlowError.invalidCallback
        }
        guard let code = singleValue(named: "code", in: items), !code.isEmpty else {
            throw AmbitiousAuthFlowError.invalidCallback
        }
        return code
    }

    private func singleValue(named name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0].value
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func userFacingMessage(for error: Error) -> String {
        switch error {
        case AmbitiousAuthFlowError.invalidToken,
             AmbitiousAuthFlowError.invalidCallback,
             AmbitiousAuthFlowError.invalidDiscovery,
             AmbitiousAuthFlowError.invalidUserInfo:
            return "Sign-in couldn't be verified. Please try again."
        case AmbitiousAuthFlowError.keychain:
            return "Sign-in worked, but the account couldn't be saved securely in Keychain."
        default:
            return "Couldn't reach Ambitious. Check your connection and try again."
        }
    }
}

extension AmbitiousAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? fallbackAnchor
    }
}
