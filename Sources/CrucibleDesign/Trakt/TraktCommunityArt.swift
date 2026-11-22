import CrucibleCore
import ImageIO
@preconcurrency import UIKit

/// A Trakt member's face: their avatar through the server's image cache, or their initials on a gradient of their own while
/// it loads or when they have none. VIP members get a thin accent ring.
package final class TraktAvatarView: UIView {
    private let gradient = CAGradientLayer()
    private let initials = UILabel()
    private let imageView = UIImageView()
    private let diameter: CGFloat
    private var loadTask: Task<Void, Never>?
    private var shownURL: URL?

    package init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = diameter / 2
        layer.masksToBounds = true
        layer.insertSublayer(gradient, at: 0)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        initials.font = UIFont.systemFont(ofSize: diameter * 0.38, weight: .bold)
        initials.textColor = Theme.Color.onArt
        initials.textAlignment = .center
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.ignoreIntrinsicSize()
        for view in [initials, imageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter)])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    package func configure(_ user: TraktUser?) {
        initials.text = user?.initials ?? ""
        gradient.colors = Self.colors(for: user?.username ?? "").map(\.cgColor)
        layer.borderWidth = user?.isVIP == true ? max(1.5, diameter / 26) : 0
        layer.borderColor = Theme.Color.accent.cgColor
        let url = user?.avatarURL
        guard url != shownURL else { return }
        shownURL = url
        loadTask?.cancel()
        imageView.image = nil
        imageView.alpha = 0
        guard let url else { return }
        let width = Int(diameter * max(traitCollection.displayScale, 2))
        loadTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: url.absoluteString, width: width)
            guard !Task.isCancelled, let self, self.shownURL == url, let image else { return }
            self.imageView.image = image
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) { self.imageView.alpha = 1 }
        }
    }

    /// Two warm colours picked by the username, so a member keeps the same monogram everywhere.
    private static func colors(for username: String) -> [UIColor] {
        let palettes: [(UInt32, UInt32)] = [
            (0x2B2455, 0xB0483F), (0x0F3D3E, 0x3FA796), (0x3B1F4A, 0xC0587E), (0x1E3A5F, 0x4F8EDC),
            (0x4A2C17, 0xD08A3C), (0x22313F, 0x7A9CB8), (0x3A1C1C, 0xD1513C), (0x1F3B2B, 0x7DBB5B),
        ]
        let hash = username.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFF_FFFF }
        let pair = palettes[hash % palettes.count]
        return [UIColor(hex: pair.0), UIColor(hex: pair.1)]
    }
}

/// Turns a comment's text into what a label or text view draws: Markdown styled, quoted lines indented, links marked, and each
/// inline spoiler drawn as a solid bar until it is revealed.
@MainActor
package enum TraktCommentTextFormatter {
    /// The attribute that marks a spoiler's characters, so a tap on one can reveal the comment.
    package static let spoilerKey = NSAttributedString.Key("crucible.traktSpoiler")

    package static func attributed(_ text: TraktCommentText, font: UIFont, color: UIColor, revealed: Bool, lineSpacing: CGFloat = 2) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let quoteParagraph = NSMutableParagraphStyle()
        quoteParagraph.lineSpacing = lineSpacing
        quoteParagraph.firstLineHeadIndent = 12
        quoteParagraph.headIndent = 12
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.font(font, for: run.styles), .foregroundColor: color, .paragraphStyle: paragraph]
            if run.styles.contains(.quote) {
                attributes[.paragraphStyle] = quoteParagraph
                attributes[.foregroundColor] = Theme.Color.labelSecondary
            }
            if run.styles.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.styles.contains(.code) { attributes[.backgroundColor] = Theme.Color.surfaceHigh }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = Theme.Color.accentText
            }
            if run.isSpoiler {
                attributes[spoilerKey] = true
                if !revealed {
                    attributes[.foregroundColor] = Theme.Color.labelTertiary
                    attributes[.backgroundColor] = Theme.Color.labelTertiary
                    attributes[.link] = nil
                }
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private static func font(_ base: UIFont, for styles: Set<TraktCommentText.Style>) -> UIFont {
        if styles.contains(.code) {
            return Theme.Font.scaled(.body, UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular))
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if styles.contains(.bold) { traits.insert(.traitBold) }
        if styles.contains(.italic) || styles.contains(.quote) { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits)) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}

/// Emoji drawn as images, for menus that show a picture per action.
@MainActor
package enum TraktEmojiImage {
    private static var cache: [String: UIImage] = [:]

    package static func image(_ emoji: String, size: CGFloat = 26) -> UIImage {
        let key = "\(emoji)-\(size)"
        if let cached = cache[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size)]
        let measured = (emoji as NSString).size(withAttributes: attributes)
        let side = ceil(max(measured.width, measured.height))
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            (emoji as NSString).draw(at: CGPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2), withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }
}

/// Trakt's ten-point vote spread as bars that rise into place, the most given score in full accent.
package final class TraktHistogramView: UIView {
    private let bars = (1...10).map { _ in UIView() }
    private var heights: [NSLayoutConstraint] = []
    private var shown: TraktRatingDistribution?
    private let maxHeight: CGFloat

    /// `maxHeight` is the tallest bar; the phone draws 54 points, the television twice that.
    package init(maxHeight: CGFloat = 54) {
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        let barRow = UIStackView(arrangedSubviews: bars)
        barRow.axis = .horizontal
        barRow.distribution = .fillEqually
        barRow.alignment = .bottom
        barRow.spacing = maxHeight / 13
        barRow.translatesAutoresizingMaskIntoConstraints = false
        barRow.heightAnchor.constraint(equalToConstant: maxHeight).isActive = true
        for bar in bars {
            bar.layer.cornerRadius = maxHeight / 18
            bar.layer.cornerCurve = .continuous
            bar.backgroundColor = Theme.Color.accent.withAlphaComponent(0.32)
            let height = bar.heightAnchor.constraint(equalToConstant: 3)
            height.isActive = true
            heights.append(height)
        }
        let low = Self.axisLabel("1")
        let high = Self.axisLabel("10")
        let spacer = UIView()
        let axis = UIStackView(arrangedSubviews: [low, spacer, high])
        axis.axis = .horizontal
        let caption = Self.axisLabel(TraktCommunityCopy.ratingSpread)
        caption.textAlignment = .center
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.75
        let stack = UIStackView(arrangedSubviews: [barRow, axis, caption])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private static func axisLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.caption2Regular
        label.textColor = Theme.Color.labelTertiary
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    package func show(_ distribution: TraktRatingDistribution, animated: Bool) {
        guard distribution != shown else { return }
        let first = shown == nil
        shown = distribution
        let peak = max(distribution.peakShare, 0.0001)
        let mode = distribution.mode
        layoutIfNeeded()
        for (index, bar) in bars.enumerated() {
            let share = distribution.share(of: index + 1)
            heights[index].constant = max(3, maxHeight * CGFloat(share / peak))
            bar.backgroundColor = index + 1 == mode ? Theme.Color.accent : Theme.Color.accent.withAlphaComponent(0.22 + 0.5 * CGFloat(share / peak))
        }
        accessibilityLabel = TraktCommunityCopy.ratingSpread
        accessibilityValue = (1...10).map { "\($0): \(Int((distribution.share(of: $0) * 100).rounded()))%" }.joined(separator: ", ")
        guard animated, first, !UIAccessibility.isReduceMotionEnabled, window != nil else { return }
        for (index, bar) in bars.enumerated() {
            bar.transform = CGAffineTransform(scaleX: 1, y: 0.01).translatedBy(x: 0, y: maxHeight)
            UIView.animate(withDuration: 0.7, delay: 0.04 * Double(index), usingSpringWithDamping: 0.75, initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
                bar.transform = .identity
            }
        }
    }
}

extension UIFont {
    /// The same font in another of the system's designs, such as rounded.
    package func withSystemDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(design) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// A GIF someone attached to a Trakt comment, played as it plays on Trakt's site, or held on its first frame under Reduce
/// Motion. Frames are decoded once, scaled down, and kept in memory while the app runs.
package final class TraktGIFView: UIView {
    private let imageView = UIImageView()
    private let badge = UILabel()
    private var shownURL: URL?
    private var loadTask: Task<Void, Never>?

    package init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.ignoreIntrinsicSize()
        badge.text = " GIF "
        badge.font = Theme.Font.badge
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badge.layer.cornerRadius = 4
        badge.layer.masksToBounds = true
        for view in [imageView, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "GIF"
        accessibilityTraits = .image
    }

    package required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    package func show(_ url: URL?) {
        guard url != shownURL else { return }
        shownURL = url
        loadTask?.cancel()
        imageView.image = nil
        guard let url else { return }
        let still = UIAccessibility.isReduceMotionEnabled
        loadTask = Task { [weak self] in
            let image = await TraktGIFCache.shared.image(at: url, still: still)
            guard !Task.isCancelled, let self, self.shownURL == url else { return }
            self.imageView.image = image
        }
    }
}

/// Decoded comment GIFs, each fetched once.
private actor TraktGIFCache {
    static let shared = TraktGIFCache()
    private let cache = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 40
    }

    func image(at url: URL, still: Bool) async -> UIImage? {
        let key = "\(still ? "still" : "moving")|\(url.absoluteString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let task = running[key as String] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.decode(data, still: still)
        }
        running[key as String] = task
        let image = await task.value
        running[key as String] = nil
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// The GIF's frames scaled to at most 480 points on their longer side, at most 150 of them, timed as the file says.
    private static func decode(_ data: Data, still: Bool) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), still ? 1 : 150)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += delay < 0.02 ? 0.1 : delay
        }
        guard !frames.isEmpty else { return nil }
        return frames.count == 1 ? frames[0] : UIImage.animatedImage(with: frames, duration: duration)
    }
}
