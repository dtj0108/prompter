import CryptoKit
import Foundation
import Testing
@testable import Prompter

@Suite("Ambitious PKCE")
struct AmbitiousPKCETests {
    @Test("RFC 7636 S256 test vector")
    func rfc7636S256Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(AmbitiousPKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Generated verifier uses the RFC 7636 alphabet and length")
    func generatedVerifier() throws {
        let verifier = try AmbitiousPKCE.verifier()
        #expect(verifier.count == 43)
        #expect(verifier.range(of: "[^A-Za-z0-9_-]", options: .regularExpression) == nil)
    }
}

@Suite("Ambitious ID-token validation")
struct AmbitiousJWTValidatorTests {
    private let issuer = "https://issuer.example/auth/v1"
    private let clientID = "prompter-client"
    private let nonce = "one-time-nonce"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Valid ES256 token")
    func validES256Token() throws {
        let fixture = try JWTFixture()
        let claims = try AmbitiousJWTValidator.validate(
            try fixture.token(payload: payload()),
            jwks: fixture.jwks,
            issuer: issuer,
            clientID: clientID,
            nonce: nonce,
            now: now
        )
        #expect(claims.subject == "user-fixture-1")
        #expect(claims.email == "person@example.com")
        #expect(claims.emailVerified)
    }

    @Test("Wrong issuer")
    func wrongIssuer() throws {
        let fixture = try JWTFixture()
        var claims = payload()
        claims["iss"] = "https://wrong.example/auth/v1"
        #expect(throws: AmbitiousJWTError.wrongIssuer) {
            try AmbitiousJWTValidator.validate(
                try fixture.token(payload: claims), jwks: fixture.jwks,
                issuer: issuer, clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    @Test("Wrong audience")
    func wrongAudience() throws {
        let fixture = try JWTFixture()
        var claims = payload()
        claims["aud"] = ["some-other-client"]
        #expect(throws: AmbitiousJWTError.wrongAudience) {
            try AmbitiousJWTValidator.validate(
                try fixture.token(payload: claims), jwks: fixture.jwks,
                issuer: issuer, clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    @Test("Expired token")
    func expiredToken() throws {
        let fixture = try JWTFixture()
        var claims = payload()
        claims["exp"] = now.timeIntervalSince1970 - 61
        #expect(throws: AmbitiousJWTError.expired) {
            try AmbitiousJWTValidator.validate(
                try fixture.token(payload: claims), jwks: fixture.jwks,
                issuer: issuer, clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    @Test("Bad nonce")
    func badNonce() throws {
        let fixture = try JWTFixture()
        var claims = payload()
        claims["nonce"] = "replayed-nonce"
        #expect(throws: AmbitiousJWTError.badNonce) {
            try AmbitiousJWTValidator.validate(
                try fixture.token(payload: claims), jwks: fixture.jwks,
                issuer: issuer, clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    @Test("alg none")
    func algNone() throws {
        let fixture = try JWTFixture()
        let token = try fixture.unsignedToken(algorithm: "none", payload: payload())
        #expect(throws: AmbitiousJWTError.unsupportedAlgorithm) {
            try AmbitiousJWTValidator.validate(
                token, jwks: fixture.jwks, issuer: issuer,
                clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    @Test("HS256")
    func hs256() throws {
        let fixture = try JWTFixture()
        let token = try fixture.unsignedToken(algorithm: "HS256", payload: payload())
        #expect(throws: AmbitiousJWTError.unsupportedAlgorithm) {
            try AmbitiousJWTValidator.validate(
                token, jwks: fixture.jwks, issuer: issuer,
                clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    @Test("Unknown kid")
    func unknownKeyID() throws {
        let fixture = try JWTFixture()
        let token = try fixture.token(payload: payload(), keyID: "unknown-fixture-key")
        #expect(throws: AmbitiousJWTError.unknownKeyID) {
            try AmbitiousJWTValidator.validate(
                token, jwks: fixture.jwks, issuer: issuer,
                clientID: clientID, nonce: nonce, now: now
            )
        }
    }

    private func payload() -> [String: Any] {
        [
            "iss": issuer,
            "sub": "user-fixture-1",
            "aud": [clientID, "another-approved-audience"],
            "exp": now.timeIntervalSince1970 + 600,
            "iat": now.timeIntervalSince1970 - 5,
            "nonce": nonce,
            "email": "person@example.com",
            "email_verified": true,
        ]
    }
}

@Suite("Ambitious product gate")
struct AmbitiousAuthGateTests {
    @Test("Fresh state requires sign-in")
    func freshState() {
        #expect(AmbitiousAuthGate.decision(
            hasCachedIdentity: false, refreshOutcome: .notAttempted, dictationInFlight: false
        ) == .requireSignIn)
    }

    @Test("Cached identity survives offline refresh failure")
    func offlineGrace() {
        #expect(AmbitiousAuthGate.decision(
            hasCachedIdentity: true, refreshOutcome: .transientFailure, dictationInFlight: false
        ) == .allow)
    }

    @Test("Successful refresh keeps access")
    func successfulRefresh() {
        #expect(AmbitiousAuthGate.decision(
            hasCachedIdentity: true, refreshOutcome: .success, dictationInFlight: false
        ) == .allow)
    }

    @Test("Definitive revocation signs out while idle")
    func revokedWhileIdle() {
        #expect(AmbitiousAuthGate.decision(
            hasCachedIdentity: true, refreshOutcome: .definitiveRevocation, dictationInFlight: false
        ) == .signOut)
    }

    @Test("Definitive revocation waits for active dictation")
    func revokedDuringDictation() {
        #expect(AmbitiousAuthGate.decision(
            hasCachedIdentity: true, refreshOutcome: .definitiveRevocation, dictationInFlight: true
        ) == .deferSignOut)
    }

    @Test("Only OAuth 400 invalid_grant is definitive revocation")
    func refreshFailureClassification() {
        #expect(AmbitiousRefreshFailureClassifier.outcome(
            httpStatus: 400, oauthError: "invalid_grant"
        ) == .definitiveRevocation)
        #expect(AmbitiousRefreshFailureClassifier.outcome(
            httpStatus: 400, oauthError: "invalid_client"
        ) == .transientFailure)
        #expect(AmbitiousRefreshFailureClassifier.outcome(
            httpStatus: 401, oauthError: "invalid_grant"
        ) == .transientFailure)
        #expect(AmbitiousRefreshFailureClassifier.outcome(
            httpStatus: 503, oauthError: nil
        ) == .transientFailure)
    }
}

private struct JWTFixture {
    let privateKey: P256.Signing.PrivateKey
    let jwks: AmbitiousJWKSet
    let keyID = "fixture-es256-key"

    init() throws {
        var scalar = Data(repeating: 0, count: 31)
        scalar.append(1)
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        let representation = privateKey.publicKey.x963Representation
        let x = representation.subdata(in: 1..<33)
        let y = representation.subdata(in: 33..<65)
        jwks = AmbitiousJWKSet(keys: [
            AmbitiousJWK(
                kty: "EC", kid: keyID, use: "sig", alg: "ES256", crv: "P-256",
                x: Base64URL.encode(x), y: Base64URL.encode(y)
            )
        ])
    }

    func token(payload: [String: Any], keyID: String? = nil) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": keyID ?? self.keyID, "typ": "JWT"]
        let signingInput = try encoded(header) + "." + encoded(payload)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature.rawRepresentation)
    }

    func unsignedToken(algorithm: String, payload: [String: Any]) throws -> String {
        let header: [String: Any] = ["alg": algorithm, "kid": keyID, "typ": "JWT"]
        return try encoded(header) + "." + encoded(payload) + ".AA"
    }

    private func encoded(_ object: [String: Any]) throws -> String {
        Base64URL.encode(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}
