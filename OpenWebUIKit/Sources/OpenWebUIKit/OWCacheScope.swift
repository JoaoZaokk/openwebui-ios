import Foundation

public extension OpenWebUIClient {
    /// What on-device data is scoped to: the server's origin and the account's id.
    ///
    /// Two accounts on one server, or one account on two servers, must never see
    /// each other's cached conversations — and a conversation held back for a
    /// failed save must be pushed to the server it was written against, with the
    /// account that wrote it. The origin is the same normalization `updateConfig`
    /// uses to decide whether a token may be kept, so "same server" means the
    /// same thing in both places.
    static func cacheOwner(origin url: URL, userID: String) -> String {
        "\(origin(url))|\(userID)"
    }
}
