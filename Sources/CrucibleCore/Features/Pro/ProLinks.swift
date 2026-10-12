import Foundation

/// The legal pages Apple expects next to a subscription, and the pages that explain Crucible Pro.
package enum ProLinks {
    package static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    package static let privacyPolicy = URL(string: "https://midgarcorp.cc/crucible/privacy/")!
    package static let support = URL(string: "https://github.com/guitaripod/Crucible/issues")!
    package static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}
