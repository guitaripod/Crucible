import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The Trakt actions a title's menus offer on iPhone and iPad.
@MainActor
enum TraktPhoneActions {
    /// Check In, or Cancel Check-In while checked in to this title, when a Trakt account is connected and sends changes, for a
    /// movie or an episode.
    static func checkInAction(ratingKey: String, mediaType: String, durationSecs: Double?, api: APIClient, host: UIViewController) -> UIAction? {
        guard TraktAccount.shared.isConnected, TraktAccount.shared.choices.sendsChanges,
              mediaType == "movie" || mediaType == "episode" else { return nil }
        guard !TraktCheckin.isCheckedIn(to: ratingKey) else {
            return UIAction(title: TraktCopy.cancelCheckIn, image: UIImage(systemName: "mappin.slash"), attributes: .destructive) { [weak host] _ in
                Task { @MainActor [weak host] in
                    do {
                        try await TraktCheckin.cancel()
                        guard let host else { return }
                        TraktToast.show(TraktCopy.checkInCancelled, symbol: "mappin.slash", in: host.navigationController?.view ?? host.view, belowBar: host.navigationController != nil)
                    } catch {
                        host?.presentTraktMessage(error.localizedDescription)
                    }
                }
            }
        }
        return UIAction(title: TraktCopy.checkIn, image: UIImage(systemName: "mappin.and.ellipse")) { [weak host] _ in
            guard let host else { return }
            checkIn(ratingKey: ratingKey, durationSecs: durationSecs, api: api, host: host)
        }
    }

    static func checkIn(ratingKey: String, durationSecs: Double?, api: APIClient, host: UIViewController, replacing: Bool = false) {
        Task { @MainActor [weak host] in
            do {
                if replacing { try await TraktCheckin.cancel() }
                switch try await TraktCheckin.checkIn(ratingKey: ratingKey, durationSecs: durationSecs, api: api) {
                case .checkedIn:
                    Haptics.success()
                    guard let host else { return }
                    TraktToast.show(TraktCopy.checkedIn, symbol: "mappin.and.ellipse", in: host.navigationController?.view ?? host.view, belowBar: host.navigationController != nil)
                case .notMatched:
                    host?.presentTraktMessage(TraktCopy.checkInNotMatched)
                case .alreadyWatching(let until):
                    guard let host else { return }
                    let time = until.map { $0.formatted(date: .omitted, time: .shortened) }
                    let alert = UIAlertController(title: TraktCopy.checkIn, message: TraktCopy.alreadyCheckedIn(until: time), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: TraktCopy.replaceCheckIn, style: .default) { [weak host] _ in
                        guard let host else { return }
                        checkIn(ratingKey: ratingKey, durationSecs: durationSecs, api: api, host: host, replacing: true)
                    })
                    alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                    host.present(alert, animated: true)
                }
            } catch {
                MidgarLog.notice("Trakt check-in failed: \(error.localizedDescription)", category: .trakt)
                host?.presentTraktMessage(error.localizedDescription)
            }
        }
    }
}

extension UIViewController {
    /// A one-button alert carrying a Trakt message.
    func presentTraktMessage(_ message: String) {
        let alert = UIAlertController(title: TraktCopy.name, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

/// A small glass capsule that confirms something happened on Trakt, at the top of a screen or of the player, gone after a
/// few seconds. It never takes a touch, so nothing underneath stops working.
@MainActor
enum TraktToast {
    /// Shows "Marked watched on Trakt" over whatever `window` shows, the player included, when it is the window in front.
    static func observeWatched(in window: UIWindow) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .traktMarkedWatched, object: nil, queue: .main) { [weak window] note in
            let notice = note.object as? TraktWatchedNotice
            MainActor.assumeIsolated {
                guard let window, let notice, window.windowScene?.activationState == .foregroundActive else { return }
                show(TraktCopy.markedWatched, detail: [notice.subtitle, notice.title].compactMap { $0 }.joined(separator: " · "), in: window)
            }
        }
    }

    /// `belowBar` keeps the toast under a navigation bar, clear of its buttons.
    static func show(_ text: String, detail: String? = nil, symbol: String = "checkmark", in container: UIView, belowBar: Bool = false) {
        container.subviews.filter { $0.accessibilityIdentifier == "trakt.toast" }.forEach { $0.removeFromSuperview() }
        let toast = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        toast.accessibilityIdentifier = "trakt.toast"
        toast.isUserInteractionEnabled = false
        toast.layer.cornerRadius = 26
        toast.layer.cornerCurve = .continuous
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false

        let badge = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))
        badge.tintColor = Theme.Color.onAccent
        badge.contentMode = .center
        badge.backgroundColor = Theme.Color.accent
        badge.layer.cornerRadius = 15
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 30), badge.heightAnchor.constraint(equalToConstant: 30)])

        let title = UILabel()
        title.text = text
        title.font = Theme.Font.subheadlineSemibold
        title.textColor = .white
        title.adjustsFontForContentSizeCategory = true
        let subtitle = UILabel()
        subtitle.text = detail
        subtitle.font = Theme.Font.caption1Regular
        subtitle.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitle.isHidden = detail == nil
        let texts = UIStackView(arrangedSubviews: [title, subtitle])
        texts.axis = .vertical
        let row = UIStackView(arrangedSubviews: [badge, texts])
        row.spacing = Theme.Space.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        toast.contentView.addSubview(row)
        container.addSubview(toast)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: toast.contentView.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: toast.contentView.bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: toast.contentView.leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: toast.contentView.trailingAnchor, constant: -18),
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: belowBar ? 56 : Theme.Space.s),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: Theme.Space.m),
        ])
        title.accessibilityIdentifier = "trakt.toast.text"
        UIAccessibility.post(notification: .announcement, argument: [text, detail].compactMap { $0 }.joined(separator: ", "))
        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: -12)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduceMotion ? 0 : 0.3) {
            toast.alpha = 1
            toast.transform = .identity
        }
        UIView.animate(withDuration: reduceMotion ? 0 : 0.3, delay: 4, options: [.beginFromCurrentState]) {
            toast.alpha = 0
        } completion: { _ in
            toast.removeFromSuperview()
        }
    }
}
