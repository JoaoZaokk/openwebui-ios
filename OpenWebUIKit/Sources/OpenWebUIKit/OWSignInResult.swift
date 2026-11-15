import Foundation

// What a sign-in can answer with in Open WebUI 0.13.
//
// `POST /api/v1/auths/signin`, `/auths/ldap` and `/auths/oauth/{provider}/token/
// exchange` all end in `create_signin_response` (backend utils/auth.py:671),
// which no longer always returns a session. It returns one of three bodies:
//
//   { token, token_type, expires_at, id, email, … }      a session
//   { next_step: verify|enroll|recover, challenge_token,
//     expires_in }                                        an MFA step
//   { next_step: "pending" }                              awaiting approval
//
// The client modelled only the first, so an account with two-step verification
// failed with "Resposta inesperada do servidor" and no way forward.

public enum OWMFAKind: String, Equatable, Sendable {
    /// The account has an authenticator: ask for its six digits.
    case verify
    /// MFA is required and the account has none yet: the QR code and the
    /// recovery codes belong to the web app's own screens.
    case enroll
    /// An operator reset the account's MFA: it needs the operator's token, then
    /// enrolment again.
    case recover
}

public struct OWMFAChallenge: Equatable, Sendable {
    public var kind: OWMFAKind
    public var challengeToken: String
    /// Seconds the server gave it (`CHALLENGE_SECONDS`, 300).
    public var expiresIn: Int

    public init(kind: OWMFAKind, challengeToken: String, expiresIn: Int = 300) {
        self.kind = kind; self.challengeToken = challengeToken; self.expiresIn = expiresIn
    }

    /// What goes on the wire. An authenticator shows "123 456"; the server wants
    /// six digits. A recovery code is sent as typed, trimmed.
    public static func normalizedCode(_ raw: String, recovery: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return recovery ? trimmed : trimmed.filter { !$0.isWhitespace }
    }
}

public enum OWSignInResult: Sendable {
    case session(OWSession)
    case mfa(OWMFAChallenge)
    /// `{next_step: "pending"}`: the account exists and is not approved yet.
    case pending

    /// Reads whichever of the three the server sent. `next_step` decides first —
    /// a body that names a step is never also a session — so a future server
    /// that adds a field beside `token` cannot turn a challenge into one.
    public static func decode(_ data: Data) throws -> OWSignInResult {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OWError.decoding(String(decoding: data.prefix(120), as: UTF8.self))
        }
        if let step = object["next_step"] as? String {
            if step == "pending" { return .pending }
            guard let kind = OWMFAKind(rawValue: step) else {
                throw OWError.decoding("next_step: \(step)")
            }
            guard let challenge = object["challenge_token"] as? String, !challenge.isEmpty else {
                throw OWError.decoding("next_step \(step) without challenge_token")
            }
            let expires = (object["expires_in"] as? Int) ?? 300
            return .mfa(OWMFAChallenge(kind: kind, challengeToken: challenge, expiresIn: expires))
        }
        do { return .session(try JSONDecoder().decode(OWSession.self, from: data)) }
        catch { throw OWError.decoding(String(describing: error)) }
    }
}

/// Why `POST /api/v1/auths/mfa/verify` said no, in the terms the screen needs:
/// a sentence, and whether the challenge is still alive to try again with.
///
/// The server's own details are English (routers/mfa.py, utils/mfa.py) and the
/// same status carries more than one meaning — a 401 is a wrong code or an
/// expired step, a 429 is too many codes on this challenge or too many attempts
/// from this address — so the detail is read, not only the number.
public enum OWMFAFailure: Equatable, Sendable {
    case invalidCode
    case expired
    case awaitingApproval
    case mfaDisabled
    case tooManyCodes
    case tooManyAttempts
    case authenticationChanged
    case busy
    case unavailable
    case other(String?)

    public static func classify(status: Int, detail: String?) -> OWMFAFailure {
        let d = (detail ?? "").lowercased()
        switch status {
        case 401:
            if d.contains("expired") || d.contains("start again") { return .expired }
            // `get_auth` (utils/mfa.py) answers a challenge whose account was
            // deleted or deactivated since it was issued. No code can fix that,
            // and showing 'wrong code' on every retry kept the person on a dead
            // challenge (Auth review #9).
            if d.contains("invalid authentication request") { return .authenticationChanged }
            return .invalidCode
        case 403:
            if d.contains("awaiting approval") { return .awaitingApproval }
            if d.contains("disabled") { return .mfaDisabled }
            return .other(detail)
        case 429:
            return d.contains("too many codes") ? .tooManyCodes : .tooManyAttempts
        case 409:
            return d.contains("busy") ? .busy : .authenticationChanged
        case 503:
            return .unavailable
        default:
            return .other(detail)
        }
    }

    /// True when the code just sent cannot be followed by another: the person
    /// has to sign in again to get a new challenge. A wrong code, a busy server
    /// and the address-wide rate limit leave this one standing.
    public var endsChallenge: Bool {
        switch self {
        case .invalidCode, .busy, .unavailable, .tooManyAttempts, .other: return false
        case .expired, .awaitingApproval, .mfaDisabled, .tooManyCodes, .authenticationChanged: return true
        }
    }

    public var message: String {
        switch self {
        case .invalidCode:
            return L("Código inválido ou já usado. Confira o app autenticador e tente de novo.")
        case .expired:
            return L("Esta verificação expirou. Entre de novo.")
        case .awaitingApproval:
            return L("Sua conta está aguardando aprovação do administrador.")
        case .mfaDisabled:
            return L("A verificação em duas etapas foi desativada. Entre de novo.")
        case .tooManyCodes:
            return L("Muitos códigos errados. Entre de novo.")
        case .tooManyAttempts:
            return L("Muitas tentativas. Aguarde alguns minutos e tente de novo.")
        case .authenticationChanged:
            return L("Sua autenticação mudou. Entre de novo.")
        case .busy:
            return L("O servidor está ocupado. Tente de novo em instantes.")
        case .unavailable:
            return L("A autenticação está indisponível no momento. Tente de novo mais tarde.")
        case .other(let detail):
            if let detail, !detail.isEmpty { return detail }
            return L("Não foi possível verificar o código.")
        }
    }
}

/// `verifyMFA`'s failure, so a caller can tell "the server refused this code"
/// from "the network failed" — they need different screens.
public struct OWMFAError: LocalizedError, Sendable {
    public let failure: OWMFAFailure
    public init(failure: OWMFAFailure) { self.failure = failure }
    public var errorDescription: String? { failure.message }
}
