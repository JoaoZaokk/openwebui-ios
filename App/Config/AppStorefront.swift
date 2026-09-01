import Foundation
import StoreKit
import OpenWebUIKit

/// Which App Store this install belongs to.
///
/// Used for one thing: a sign-in provider that cannot be reached from a whole
/// country should not be offered there. The storefront is the right signal for
/// that and the device language is the wrong one — Chinese is the language of
/// Taiwan, Hong Kong, Singapore and Malaysia too, where Google is reachable, and
/// a Chinese speaker in Lisbon has no firewall in front of them. Hiding by
/// language would take a working button away from most of the people who speak
/// it, to help the few who cannot use it.
///
/// The device region is a settings toggle rather than a place, so the storefront
/// is asked first and the region is only the fallback.
@MainActor
enum AppStorefront {
    /// ISO 3166-1 alpha-2, uppercased. nil until `refresh()` has answered.
    private(set) static var country: String?

    /// StoreKit answers in alpha-3; only the countries this file reasons about
    /// need to be here, and the region fallback covers everywhere else.
    private static let alpha2ForAlpha3 = ["CHN": "CN"]

    static func refresh() async {
        let storefront = await Storefront.current?.countryCode.uppercased()
        country = storefront.flatMap { alpha2ForAlpha3[$0] }
            ?? Locale.current.region?.identifier.uppercased()
    }

    /// Filters an SSO provider list for where this app is installed. The rule
    /// itself lives in `OWSSOAvailability`, which is testable; this only supplies
    /// the country.
    static func reachableProviders<T>(_ providers: [T], key: (T) -> String,
                                      otherWaysIn: Bool) -> [T] {
        let kept = Set(OWSSOAvailability.reachable(providers.map(key), country: country,
                                                   otherWaysIn: otherWaysIn))
        return providers.filter { kept.contains(key($0)) }
    }
}
