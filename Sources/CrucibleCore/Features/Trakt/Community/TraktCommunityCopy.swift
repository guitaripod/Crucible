import Foundation

/// The words of a title's Trakt community, shared by iPhone, iPad and Apple TV.
package enum TraktCommunityCopy {
    package static let title = String(localized: "Community", comment: "Heading of the Trakt community section on a title's page")
    package static let comments = String(localized: "Comments", comment: "Title of the screen listing a title's Trakt comments")
    package static let seeAll = String(localized: "See All", comment: "Button that opens every Trakt comment on a title")
    package static let spoilerWord = String(localized: "spoiler", comment: "Stands in for hidden spoiler text in a comment preview, inside brackets")

    package static let writeReview = String(localized: "Write a Review", comment: "Button that starts a Trakt comment or review on a title")
    package static let reply = String(localized: "Reply", comment: "Button that replies to a Trakt comment")
    package static let review = String(localized: "Review", comment: "Badge on a Trakt comment of 200 words or more")
    package static let spoiler = String(localized: "Spoiler", comment: "Badge on a Trakt comment marked as a spoiler, and the composer's spoiler switch")
    package static let edited = String(localized: "Edited", comment: "Shown on a Trakt comment its author changed after posting")
    package static let you = String(localized: "You", comment: "Shown in place of the viewer's own name on their Trakt comment")
    package static let like = String(localized: "Like", comment: "Action that likes a Trakt comment")
    package static let unlike = String(localized: "Unlike", comment: "Action that takes back a like of a Trakt comment")
    package static let react = String(localized: "React", comment: "Action that opens the reactions for a Trakt comment")
    package static let reactions = String(localized: "Reactions", comment: "Heading of the reactions a Trakt comment received")
    package static let copyText = String(localized: "Copy Text", comment: "Action that copies a Trakt comment's text")
    package static let openOnTrakt = String(localized: "Open on Trakt", comment: "Action that opens a comment or member on Trakt's website")
    package static let edit = String(localized: "Edit", comment: "Action that edits the viewer's own Trakt comment")
    package static let delete = String(localized: "Delete", comment: "Action that deletes the viewer's own Trakt comment")
    package static let deleteTitle = String(localized: "Delete This Comment?", comment: "Confirmation title for deleting the viewer's Trakt comment")
    package static let deleteMessage = String(localized: "It's removed from Trakt for everyone, with its likes and reactions.", comment: "Confirmation message for deleting the viewer's Trakt comment")
    package static let deleted = String(localized: "Comment deleted", comment: "Confirmation after deleting a Trakt comment")
    package static let report = String(localized: "Report", comment: "Menu that reports a Trakt comment or member to Trakt's moderators")
    package static let reportTitle = String(localized: "Report to Trakt", comment: "Title of the menu of reasons to report something to Trakt's moderators")
    package static let reported = String(localized: "Reported to Trakt's moderators", comment: "Confirmation after reporting a Trakt comment or member")
    package static let posted = String(localized: "Posted to Trakt", comment: "Confirmation after posting a Trakt comment")
    package static let replied = String(localized: "Reply posted", comment: "Confirmation after posting a reply to a Trakt comment")
    package static let saved = String(localized: "Comment updated", comment: "Confirmation after editing a Trakt comment")

    package static let spoilerCover = String(localized: "Contains spoilers", comment: "Cover over a Trakt comment marked as a spoiler")
    package static let tapToReveal = String(localized: "Tap to reveal", comment: "Under the spoiler cover on iPhone and iPad")
    package static let pressToReveal = String(localized: "Press to reveal", comment: "Under the spoiler cover on Apple TV")
    package static let hiddenSpoiler = String(localized: "Hidden spoiler. Double-tap to reveal.", comment: "VoiceOver label of an inline spoiler in a Trakt comment")

    package static let statWatchers = String(localized: "Watchers", comment: "Trakt community statistic: people who watched the title")
    package static let statPlays = String(localized: "Plays", comment: "Trakt community statistic: total plays of the title")
    package static let statLists = String(localized: "Lists", comment: "Trakt community statistic: lists the title is in")
    package static let statComments = String(localized: "Comments", comment: "Trakt community statistic: comments on the title")
    package static let statFavorites = String(localized: "Favorites", comment: "Trakt community statistic: people who made the title a favorite")
    package static let statCollected = String(localized: "Collected", comment: "Trakt community statistic: people who collected the title")

    package static let whatPeopleSay = String(localized: "What People Say", comment: "Heading of what Trakt members praise and criticise about a title")
    package static let theGood = String(localized: "Loved", comment: "Group of what Trakt members praise about a title")
    package static let theBad = String(localized: "Not so much", comment: "Group of what Trakt members criticise about a title")
    package static let ratingSpread = String(localized: "How Trakt members rated it", comment: "Caption of the bar chart of Trakt's 1 to 10 votes")
    package static let watchingNowTitle = String(localized: "Watching Now", comment: "Title of the list of Trakt members watching a title right now")

    package static let emptyTitle = String(localized: "No Comments Yet", comment: "Shown when a title has no Trakt comments")
    package static let emptyMessage = String(localized: "Be the first to say what you thought.", comment: "Under No Comments Yet")
    package static let loadFailed = String(localized: "Couldn\u{2019}t Load Comments", comment: "Title when Trakt's comments did not load")
    package static let sort = String(localized: "Sort", comment: "Menu that orders a title's Trakt comments")

    package static let unlockTitle = String(localized: "See what everyone says", comment: "Headline of the card that unlocks every Trakt comment with Pro")
    package static let unlockAction = String(localized: "Unlock with Pro", comment: "Button that opens the Crucible Pro paywall from the Trakt community")
    package static let lockedSentiments = String(localized: "What people loved and didn't, from every comment, comes with Crucible Pro.", comment: "Under the hidden What People Say on a title without Pro")

    package static let composeTitle = String(localized: "New Comment", comment: "Title of the Trakt composer for a new comment")
    package static let composeReviewTitle = String(localized: "Your Review", comment: "Title of the Trakt composer once the text is long enough to be a review")
    package static let replyTitle = String(localized: "Reply", comment: "Title of the Trakt composer for a reply")
    package static let editTitle = String(localized: "Edit Comment", comment: "Title of the Trakt composer while editing")
    package static let post = String(localized: "Post", comment: "Button that posts a Trakt comment")
    package static let save = String(localized: "Save", comment: "Button that saves an edited Trakt comment")
    package static let placeholder = String(localized: "What did you think?", comment: "Placeholder of the Trakt comment composer")
    package static let replyPlaceholder = String(localized: "Write a reply", comment: "Placeholder of the Trakt reply composer")
    package static let markSpoiler = String(localized: "Contains Spoilers", comment: "Switch in the composer that marks the whole Trakt comment as a spoiler")
    package static let hidePart = String(localized: "Hide as Spoiler", comment: "Button in the composer that wraps the selected text in spoiler tags")
    package static let rulesTitle = String(localized: "Trakt\u{2019}s rules for comments", comment: "Heading of Trakt's rules in the composer")
    package static let rules = [
        String(localized: "At least five words, written in English.", comment: "Trakt comment rule"),
        String(localized: "Mark spoilers: switch on Contains Spoilers, or hide a part with Hide as Spoiler.", comment: "Trakt comment rule"),
        String(localized: "From 200 words, Trakt shows it as a review.", comment: "Trakt comment rule"),
        String(localized: "No app names or hashtags.", comment: "Trakt comment rule"),
    ]
    package static let gotIt = String(localized: "Got It", comment: "Button that closes Trakt's comment rules")
    package static let notEnglish = String(localized: "Trakt only takes comments written in English.", comment: "Composer warning when a Trakt comment looks like it is not in English")
    package static let appTag = String(localized: "Trakt doesn't allow app names or hashtags in comments.", comment: "Composer warning when a Trakt comment names the app")
    package static let discardTitle = String(localized: "Keep this draft?", comment: "Question when closing the Trakt composer with text in it")
    package static let keepDraft = String(localized: "Keep Draft", comment: "Keeps the Trakt comment being written for later")
    package static let discard = String(localized: "Discard", comment: "Throws away the Trakt comment being written")

    package static let follow = String(localized: "Follow", comment: "Button that follows a Trakt member")
    package static let following = String(localized: "Following", comment: "Button state while following a Trakt member")
    package static let requested = String(localized: "Requested", comment: "Button state after asking to follow a private Trakt member")
    package static let block = String(localized: "Block", comment: "Action that blocks a Trakt member")
    package static let unblock = String(localized: "Unblock", comment: "Action that unblocks a Trakt member")
    package static let blockTitle = String(localized: "Block This Member?", comment: "Confirmation title for blocking a Trakt member")
    package static let blockMessage = String(localized: "They stop following you, and their comments disappear from Crucible.", comment: "Confirmation message for blocking a Trakt member")
    package static let blocked = String(localized: "Member blocked", comment: "Confirmation after blocking a Trakt member")
    package static let vip = "VIP"
    package static let director = String(localized: "Director", comment: "Badge of a Trakt member who directs films")
    package static let privateProfile = String(localized: "This profile is private.", comment: "Shown for a private Trakt member")
    package static let recentComments = String(localized: "Recent Comments", comment: "Heading of a Trakt member's latest comments")
    package static let watchingNowLabel = String(localized: "Watching now", comment: "Label before what a Trakt member is watching right now")

    /// "12 watching now".
    package static func watchingNow(_ count: Int) -> String {
        String(localized: "\(count) watching now", comment: "How many Trakt members are watching a title right now")
    }

    /// "312 comments".
    package static func commentCount(_ count: Int) -> String {
        String(localized: "\(count) comments", comment: "How many Trakt comments a title has")
    }

    /// "4 replies".
    package static func replyCount(_ count: Int) -> String {
        String(localized: "\(count) replies", comment: "How many replies a Trakt comment has")
    }

    /// "18 likes".
    package static func likeCount(_ count: Int) -> String {
        String(localized: "\(count) likes", comment: "How many likes a Trakt comment has")
    }

    /// "Read all 312 comments".
    package static func readAll(_ count: Int) -> String {
        String(localized: "Read all \(count) comments", comment: "Button on the card that unlocks every Trakt comment with Pro")
    }

    /// "12 words".
    package static func wordCount(_ count: Int) -> String {
        String(localized: "\(count) words", comment: "How many words the Trakt comment being written has")
    }

    /// "3 more words".
    package static func wordsMissing(_ count: Int) -> String {
        String(localized: "\(count) more words", comment: "How many more words a Trakt comment needs before it can be posted")
    }

    /// "From 312 comments".
    package static func sentimentSource(_ count: Int) -> String {
        String(localized: "Drawn by Trakt from \(count) comments", comment: "Under What People Say: how many comments Trakt read")
    }

    /// "Rated 8/10".
    package static func authorRating(_ rating: Int) -> String {
        String(localized: "Rated \(rating)/10", comment: "A Trakt comment author's own rating of the title")
    }

    /// "Watched 3 times".
    package static func authorPlays(_ plays: Int) -> String {
        String(localized: "Watched \(plays) times", comment: "How many times a Trakt comment author watched the title")
    }

    /// "Replying to Ana".
    package static func replyingTo(_ name: String) -> String {
        String(localized: "Replying to \(name)", comment: "Composer subtitle when replying to a Trakt comment")
    }

    /// "Joined March 2014".
    package static func joined(_ date: Date) -> String {
        let month = date.formatted(.dateTime.month(.wide).year().locale(Formatters.interfaceLocale))
        return String(localized: "Joined \(month)", comment: "When a Trakt member joined, as month and year")
    }

    /// "VIP for 6 years".
    package static func vipYears(_ years: Int) -> String {
        String(localized: "VIP for \(years) years", comment: "How long a Trakt member has been VIP")
    }

    /// When a comment was written, as a short relative time ("3 days ago", "now"). A time a little ahead of this device's
    /// clock, as a comment just posted can be, reads as now.
    package static func age(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return justNow }
        return PortableFormat.relative(date, to: now, width: .short)
    }

    package static let justNow = String(localized: "Just now", comment: "When a Trakt comment was written less than a minute ago")

    /// One line a screen reader speaks for a comment: who wrote it, their rating, the text with its spoilers hidden, and how
    /// many liked and replied.
    package static func accessibilityLabel(_ comment: TraktComment, hidingSpoilers: Bool) -> String {
        var parts = [comment.user.displayName]
        if comment.isReview { parts.append(review) }
        if let rating = comment.authorRating { parts.append(authorRating(rating)) }
        if comment.isSpoiler && hidingSpoilers {
            parts.append(spoilerCover)
        } else {
            let text = TraktCommentText(comment.text)
            parts.append(hidingSpoilers ? text.textHidingSpoilers : text.plainText)
        }
        if comment.likeCount > 0 { parts.append(likeCount(comment.likeCount)) }
        if comment.replyCount > 0 { parts.append(replyCount(comment.replyCount)) }
        parts.append(age(comment.createdAt))
        return parts.joined(separator: ", ")
    }

    /// What the composer says about a draft, most pressing first, or nil when it is ready.
    package static func concern(_ draft: TraktCommentDraft) -> String? {
        for concern in draft.concerns {
            switch concern {
            case .tooShort(let missing) where draft.wordCount > 0: return wordsMissing(missing)
            case .tooShort: continue
            case .notEnglish: return notEnglish
            case .appTag: return appTag
            }
        }
        return nil
    }
}
