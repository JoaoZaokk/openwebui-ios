import Foundation

/// Which sign-in providers are worth offering where the app is installed.
///
/// Kept here, away from the view, because the interesting part is a rule and not
/// a layout: a provider unreachable from a whole country should not be offered
/// there, and yet the filter must never remove somebody's last way in.
public enum OWSSOAvailability {

    /// Providers whose own sign-in pages do not answer from a country, so the
    /// button would open onto a page that never loads.
    ///
    /// Only `google`, and only mainland China: `accounts.google.com` does not
    /// resolve through the Great Firewall. GitHub and Microsoft's login do,
    /// `oidc` is the user's own identity provider, and `feishu` is the one built
    /// for that market.
    ///
    /// Keyed by ISO 3166-1 alpha-2, matched case-insensitively.
    static let unreachable: [String: Set<String>] = ["CN": ["google"]]

    /// Filters provider keys for a country.
    ///
    /// - Parameters:
    ///   - country: alpha-2, or nil while the storefront is still unknown — in
    ///     which case nothing is filtered, because guessing wrong hides a working
    ///     button.
    ///   - otherWaysIn: whether the screen offers any other route (a password
    ///     form, LDAP). When it does not, nothing is removed: somebody whose
    ///     server offers only Google is reaching that server over a VPN already,
    ///     and the same VPN carries the sign-in. A button that fails with a
    ///     reason beats a screen with no way forward.
    public static func reachable(_ providers: [String], country: String?,
                                 otherWaysIn: Bool) -> [String] {
        guard let country, let blocked = unreachable[country.uppercased()] else { return providers }
        let kept = providers.filter { !blocked.contains($0.lowercased()) }
        return (kept.isEmpty && !otherWaysIn) ? providers : kept
    }
}
