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
public enum OWFailure {
    public static func msg(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
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
