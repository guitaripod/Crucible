import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import MidgarCore
import UIKit

/// Writes a comment, a review or a reply on Apple TV through the system keyboard, which takes dictation from the remote and
/// typing from a paired iPhone. The left column shows the text with Trakt's rules and how many words it has; the rows write,
/// put a draft in another language into English (Trakt takes only English), mark it a spoiler and post it.
final class TVCommentComposerViewController: TVSettingsScaffold {
    enum Mode {
        case new(TraktCommunitySubject, titleName: String)
        case reply(TraktComment)
        case edit(TraktComment)
    }

    private let mode: Mode
    private var text: String
    private var isSpoiler: Bool
    private var isPosting = false
    private var isTranslating = false
    /// A line over the draft after it was translated, until it is written again.
    private var note: String?
    private let screenTitle: String
    private let heading: TVSettingsHeading

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .edit(let comment):
            text = comment.text
            isSpoiler = comment.isSpoiler
            screenTitle = TraktCommunityCopy.editTitle
        case .reply(let parent):
            let draft = TraktCommentDrafts.load(TraktCommunity.draftKey(replyingTo: parent.id))
            text = draft?.text ?? ""
            isSpoiler = draft?.isSpoiler ?? false
            screenTitle = TraktCommunityCopy.replyTitle
        case .new(let subject, _):
            let draft = TraktCommentDrafts.load(TraktCommunity.draftKey(subject: subject))
            text = draft?.text ?? ""
            isSpoiler = draft?.isSpoiler ?? false
            screenTitle = TraktCommunityCopy.composeTitle
        }
        heading = TVSettingsHeading(title: screenTitle)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        render()
    }

    override var preferredFocusRowID: String? { "composer.write" }

    private var draftKey: String? {
        switch mode {
        case .new(let subject, _): return TraktCommunity.draftKey(subject: subject)
        case .reply(let parent): return TraktCommunity.draftKey(replyingTo: parent.id)
        case .edit: return nil
        }
    }

    private var context: String {
        switch mode {
        case .new(_, let titleName): return titleName
        case .reply(let parent): return TraktCommunityCopy.replyingTo(parent.user.displayName)
        case .edit: return TraktCommunityCopy.editTitle
        }
    }

    private func render() {
        let draft = TraktCommentDraft(text)
        var body = (note.map { $0 + "\n\n" } ?? "") + context + "\n\n"
        body += text.isEmpty ? TraktCommunityCopy.placeholder : text
        body += "\n\n"
        if let concern = TraktCommunityCopy.concern(draft) {
            body += concern
        } else if draft.wordCount > 0 {
            body += draft.isReview ? "\(TraktCommunityCopy.review) · \(TraktCommunityCopy.wordCount(draft.wordCount))" : TraktCommunityCopy.wordCount(draft.wordCount)
        }
        if !TraktCommentRules.wereSeen() {
            body += "\n\n" + TraktCommunityCopy.rulesTitle + "\n" + TraktCommunityCopy.rules.map { "· " + $0 }.joined(separator: "\n")
        }
        heading.setBody(body)
        let on = String(localized: "On")
        let off = String(localized: "Off")
        let writeTitle = text.isEmpty ? String(localized: "Write", comment: "Row that opens the keyboard to write a Trakt comment") : TraktCommunityCopy.edit
        var rows = [
            TVRowItem(id: "composer.write", title: writeTitle, symbol: "keyboard", accessory: .chevron),
            TVRowItem(id: "composer.spoiler", title: TraktCommunityCopy.markSpoiler, value: isSpoiler ? on : off, symbol: isSpoiler ? "eye.slash.fill" : "eye.slash"),
            TVRowItem(id: "composer.post", title: isEditingComment ? TraktCommunityCopy.save : TraktCommunityCopy.post, symbol: "paperplane.fill", isEnabled: draft.canPost && !isPosting),
        ]
        if offersTranslation(draft) {
            let title = isTranslating ? TranslationCopy.translating : TranslationCopy.translateToEnglish
            rows.insert(TVRowItem(id: "composer.translate", title: title, symbol: "translate", isEnabled: !isTranslating && !isPosting), at: 1)
        }
        setRows(rows)
    }

    /// Whether the draft reads as another language than English and this Apple TV can put it into English.
    private func offersTranslation(_ draft: TraktCommentDraft) -> Bool {
        let center = TranslationCenter.shared
        guard center.isAvailable, draft.wordCount >= 3, let language = center.language(ofDraft: text) else { return false }
        return !TranslationLanguages.isSame(language, "en")
    }

    /// Puts the draft into English on the device, spoiler tags and all.
    private func translateToEnglish() {
        let original = text
        guard !isTranslating else { return }
        isTranslating = true
        render()
        Task { [weak self] in
            let result: Result<String?, TranslationFailure>
            do throws(TranslationFailure) {
                result = .success(try await TranslationCenter.shared.translateDraft(original, into: "en"))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isTranslating = false
            if case .success(let english?) = result, self.text == original {
                self.text = english
                self.note = TranslationCopy.translatedToEnglish
                self.saveDraft()
                self.render()
            } else {
                self.render()
                if case .failure = result { self.presentAlert(title: TraktCopy.name, message: TranslationCopy.failed) }
            }
        }
    }

    private var isEditingComment: Bool {
        if case .edit = mode { return true }
        return false
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "composer.write":
            TraktCommentRules.markSeen()
            presentTextEntry(title: screenTitle, message: context, text: text, placeholder: TraktCommunityCopy.placeholder, confirmTitle: String(localized: "Done")) { [weak self] typed in
                guard let self else { return }
                self.text = typed
                self.note = nil
                self.saveDraft()
                self.render()
            }
        case "composer.translate":
            translateToEnglish()
        case "composer.spoiler":
            isSpoiler.toggle()
            saveDraft()
            render()
        case "composer.post":
            post()
        default:
            break
        }
    }

    private func saveDraft() {
        guard let draftKey else { return }
        TraktCommentDrafts.save(.init(text: text, isSpoiler: isSpoiler), for: draftKey)
    }

    private func post() {
        let draft = TraktCommentDraft(text)
        guard draft.canPost, !isPosting else { return }
        isPosting = true
        render()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoiler = isSpoiler
        let mode = mode
        Task { [weak self] in
            do {
                switch mode {
                case .new(let subject, _): _ = try await TraktCommunity.shared.post(text, spoiler: spoiler, on: subject)
                case .reply(let parent): _ = try await TraktCommunity.shared.reply(text, spoiler: spoiler, to: parent)
                case .edit(let comment): _ = try await TraktCommunity.shared.edit(comment, text: text, spoiler: spoiler)
                }
                guard let self else { return }
                TVNavigation.pop(from: self)
            } catch {
                guard let self else { return }
                self.isPosting = false
                self.render()
                self.presentAlert(title: TraktCopy.name, message: error.localizedDescription)
            }
        }
    }
}
