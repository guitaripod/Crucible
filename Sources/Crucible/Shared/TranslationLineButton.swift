import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
@preconcurrency import UIKit

/// The line under a comment or description in another language: Translate from Spanish, Translating…, Translated from
/// Spanish · Show Original, Show Translation, or Couldn't translate · Try Again. Its owner decides what a tap does.
final class TranslationLineButton: UIButton {
    private(set) var phase: TranslationCenter.Phase = .none

    init() {
        super.init(frame: .zero)
        configuration = .plain()
        contentHorizontalAlignment = .leading
        isPointerInteractionEnabled = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows what `presentation` says, or hides the line for a text in the reader's language.
    func show(_ presentation: TranslationCenter.Presentation) {
        phase = presentation.phase
        guard presentation.phase != .none, let language = presentation.sourceName else {
            isHidden = true
            return
        }
        let font = Theme.Font.footnote
        var title = AttributedString()
        func part(_ text: String, _ color: UIColor) {
            var piece = AttributedString(text)
            piece.font = font
            piece.foregroundColor = color
            title += piece
        }
        switch presentation.phase {
        case .offer:
            part(TranslationCopy.translateFrom(language), Theme.Color.accentText)
        case .translating:
            part(TranslationCopy.translating, Theme.Color.labelSecondary)
        case .translated:
            part(TranslationCopy.translatedFrom(language) + "  ·  ", Theme.Color.labelSecondary)
            part(TranslationCopy.showOriginal, Theme.Color.accentText)
        case .original:
            part(TranslationCopy.showTranslation, Theme.Color.accentText)
        case .failed:
            part(TranslationCopy.failed + "  ·  ", Theme.Color.labelSecondary)
            part(TranslationCopy.tryAgain, Theme.Color.accentText)
        case .none:
            break
        }
        var button = UIButton.Configuration.plain()
        button.attributedTitle = title
        button.image = UIImage(systemName: "translate", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))
        button.imagePadding = 5
        button.baseForegroundColor = Theme.Color.labelSecondary
        button.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        button.titleLineBreakMode = .byTruncatingTail
        configuration = button
        isEnabled = presentation.phase != .translating
        isHidden = false
    }
}
