import Foundation

/// The one way a failure becomes a sentence for the user.
///
/// Twenty-six catch blocks across the app spelled out the same expression —
/// `(error as? LocalizedError)?.errorDescription ?? error.localizedDescription`
/// — and one had wrapped it in a private helper of its own. The rules that
/// expression quietly carries are stated here so they have a home:
///
/// 1. A cancelled request is not a failure. Anything routed through
///    `OpenWebUIClient.send()` already arrives normalized to `CancellationError`,
///    so a `catch is CancellationError` before the general catch is enough there;
///    only code holding a `URLSession` directly needs `isCancellation`.
/// 2. `OWError` describes itself through `L(_:_:)`, so what comes out of `msg` is
///    already in the app language and must be rendered as-is (`Text(String)`),
///    never looked up again as a key.
/// 3. Server text (`OWError.http`'s detail) is passed through verbatim: it is the
///    server's sentence, not a catalogue key.
/// 4. A `URLError` describes itself in the *device's* language, not the app's.
///    Foundation wrote those sentences, and it writes them in whatever the phone
///    is set to, so a phone in Portuguese put "Não foi possível conectar-se ao
///    servidor." in the banner of an app the user had set to English. A
///    self-hosted client shows that banner every time the server is asleep, so
///    the common codes get sentences from the catalogue and the rest get the
///    number, which belongs to no language.
public enum OWFailure {
    public static func msg(_ e: Error) -> String {
        if let described = (e as? LocalizedError)?.errorDescription { return described }
        if let url = e as? URLError { return network(url) }
        return e.localizedDescription
    }

    private static func network(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet:
            // iOS reports "no internet" when it is the Local Network permission
            // that is off or still unanswered: Safari works, this app does not,
            // and the sentence about the internet sends the person to the wrong
            // place. The system's own log names it ("Local network prohibited").
            if e.isLocalNetworkProhibited {
                return L("O iOS bloqueou o acesso à rede local. Em Ajustes › OpenWebUI, ligue Rede Local.")
            }
            return L("Sem conexão com a internet.")
        case .timedOut:
            return L("O servidor demorou demais para responder.")
        case .cannotFindHost, .dnsLookupFailed:
            return L("Não encontrei esse servidor. Confira o endereço.")
        case .cannotConnectToHost:
            return L("Não consegui falar com o servidor. Ele está ligado?")
        case .networkConnectionLost:
            return L("A conexão caiu no meio do caminho.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return L("Falha na conexão segura com o servidor.")
        default:
            return L("Falha de rede (%@).", "\(e.errorCode)")
        }
    }
}

extension URLError {
    /// The request never left because the Local Network permission is off or the
    /// system prompt for it is still open. The code is the same
    /// `notConnectedToInternet` an offline phone reports; only the path
    /// description the system attaches (`_NSURLErrorNWPathKey`) tells them apart.
    var isLocalNetworkProhibited: Bool {
        guard code == .notConnectedToInternet else { return false }
        return userInfo.values.contains { String(describing: $0).localizedCaseInsensitiveContains("local network prohibited") }
    }
}

extension Error {
    /// Both spellings of "the caller called this off": structured concurrency's
    /// `CancellationError`, and the `URLError.cancelled` a `URLSession` task
    /// reports instead — the one `catch is CancellationError` never matches.
    /// Kept internal on purpose: the client normalizes at the transport
    /// boundary, so app code sees only the first spelling.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
