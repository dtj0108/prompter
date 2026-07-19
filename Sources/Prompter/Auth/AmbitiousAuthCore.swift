import CryptoKit
import Foundation
import Security

struct AmbitiousIdentity: Codable, Equatable {
    let issuer: String
    let subject: String
    let email: String?
    let emailVerified: Bool
}

struct AmbitiousStoredSession: Codable, Equatable {
    var clientID: String
    var identity: AmbitiousIdentity
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accessTokenExpiresAt: Date
    var lastSuccessfulRefreshAt: Date
}

enum AmbitiousRefreshOutcome: Equatable {
    case notAttempted
    case success
    case transientFailure
    case definitiveRevocation
}

enum AmbitiousGateDecision: Equatable {
    case allow
    case requireSignIn
    case signOut
    case deferSignOut
}

/// Pure policy for the product gate. A cached identity is deliberately enough
/// to keep Prompter working through an outage; only `invalid_grant` from an
/// actual refresh is treated as definitive revocation by the network layer.
enum AmbitiousAuthGate {
    static func decision(
        hasCachedIdentity: Bool,
        refreshOutcome: AmbitiousRefreshOutcome,
        dictationInFlight: Bool
    ) -> AmbitiousGateDecision {
        guard hasCachedIdentity else { return .requireSignIn }
        guard refreshOutcome == .definitiveRevocation else { return .allow }
        return dictationInFlight ? .deferSignOut : .signOut
    }
}

enum AmbitiousRefreshFailureClassifier {
    /// OAuth 2.0 defines token-endpoint `invalid_grant` as a 400 response.
    /// Current Supabase Auth returns `refresh_token_not_found` after its grant
    /// revocation endpoint invalidates the token family. Keep the accepted set
    /// deliberately narrow so infrastructure and client-configuration errors
    /// can never strand a previously signed-in user.
    static func outcome(httpStatus: Int, oauthError: String?) -> AmbitiousRefreshOutcome {
        httpStatus == 400 && ["invalid_grant", "refresh_token_not_found"].contains(oauthError)
            ? .definitiveRevocation
            : .transientFailure
    }
}

enum AmbitiousPKCE {
    static func verifier(byteCount: Int = 32) throws -> String {
        guard byteCount >= 32 else { throw AmbitiousCryptoError.invalidRandomLength }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AmbitiousCryptoError.randomGenerationFailed
        }
        return Base64URL.encode(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum AmbitiousCryptoError: Error, Equatable {
    case invalidRandomLength
    case randomGenerationFailed
}

enum AmbitiousJWTError: Error, Equatable {
    case malformed
    case unsupportedAlgorithm
    case missingKeyID
    case unknownKeyID
    case invalidKey
    case invalidSignature
    case wrongIssuer
    case wrongAudience
    case expired
    case notYetValid
    case badNonce
    case missingSubject
}

struct AmbitiousIDTokenClaims: Equatable {
    let issuer: String
    let subject: String
    let email: String?
    let emailVerified: Bool
    let expiresAt: Date
}

struct AmbitiousJWKSet: Codable, Equatable {
    let keys: [AmbitiousJWK]
}

struct AmbitiousJWK: Codable, Equatable {
    let kty: String
    let kid: String
    let use: String?
    let alg: String?
    let crv: String
    let x: String
    let y: String
}

enum AmbitiousJWTValidator {
    static func validate(
        _ token: String,
        jwks: AmbitiousJWKSet,
        issuer expectedIssuer: String,
        clientID: String,
        nonce expectedNonce: String?,
        now: Date = Date(),
        clockSkew: TimeInterval = 60
    ) throws -> AmbitiousIDTokenClaims {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              !segments[0].isEmpty,
              !segments[1].isEmpty,
              !segments[2].isEmpty,
              let headerData = Base64URL.decode(String(segments[0])),
              let payloadData = Base64URL.decode(String(segments[1])),
              let signatureData = Base64URL.decode(String(segments[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw AmbitiousJWTError.malformed }

        guard header["alg"] as? String == "ES256" else {
            throw AmbitiousJWTError.unsupportedAlgorithm
        }
        guard let kid = header["kid"] as? String, !kid.isEmpty else {
            throw AmbitiousJWTError.missingKeyID
        }
        let matchingKeys = jwks.keys.filter { $0.kid == kid }
        guard matchingKeys.count == 1 else { throw AmbitiousJWTError.unknownKeyID }
        let jwk = matchingKeys[0]
        guard jwk.kty == "EC", jwk.crv == "P-256",
              jwk.alg == nil || jwk.alg == "ES256",
              jwk.use == nil || jwk.use == "sig",
              let x = Base64URL.decode(jwk.x), x.count == 32,
              let y = Base64URL.decode(jwk.y), y.count == 32,
              signatureData.count == 64
        else { throw AmbitiousJWTError.invalidKey }

        var publicKeyBytes = Data([0x04])
        publicKeyBytes.append(x)
        publicKeyBytes.append(y)
        let publicKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyBytes)
            signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        } catch {
            throw AmbitiousJWTError.invalidKey
        }
        let signedData = Data("\(segments[0]).\(segments[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signedData) else {
            throw AmbitiousJWTError.invalidSignature
        }

        guard let issuer = payload["iss"] as? String, issuer == expectedIssuer else {
            throw AmbitiousJWTError.wrongIssuer
        }
        let audiences: [String]
        if let audience = payload["aud"] as? String {
            audiences = [audience]
        } else if let audience = payload["aud"] as? [String] {
            audiences = audience
        } else {
            throw AmbitiousJWTError.wrongAudience
        }
        guard audiences.contains(clientID) else { throw AmbitiousJWTError.wrongAudience }

        guard let exp = numericDate(payload["exp"]) else { throw AmbitiousJWTError.expired }
        guard exp.timeIntervalSince(now) >= -clockSkew else { throw AmbitiousJWTError.expired }
        if let notBefore = numericDate(payload["nbf"]), notBefore.timeIntervalSince(now) > clockSkew {
            throw AmbitiousJWTError.notYetValid
        }
        if let issuedAt = numericDate(payload["iat"]), issuedAt.timeIntervalSince(now) > clockSkew {
            throw AmbitiousJWTError.notYetValid
        }

        if let expectedNonce {
            guard let nonce = payload["nonce"] as? String,
                  constantTimeEqual(nonce, expectedNonce) else {
                throw AmbitiousJWTError.badNonce
            }
        }
        guard let subject = payload["sub"] as? String, !subject.isEmpty else {
            throw AmbitiousJWTError.missingSubject
        }

        return AmbitiousIDTokenClaims(
            issuer: issuer,
            subject: subject,
            email: payload["email"] as? String,
            emailVerified: payload["email_verified"] as? Bool ?? false,
            expiresAt: exp
        )
    }

    private static func numericDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.range(of: "[^A-Za-z0-9_-]", options: .regularExpression) == nil else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
}
