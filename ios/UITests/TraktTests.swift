import XCTest

/// Connects Trakt in the demo, whose stand-in Trakt approves the device code by itself, and checks what the plugin adds:
/// Settings › Integrations › Trakt, the ratings strip on a detail page and Check In in its menu.
@MainActor
final class TraktTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(2)
        return app
    }

    private func openTraktSettings(_ app: XCUIApplication) {
        IOSTest.tab(app, "You").tap()
        let settings = IOSTest.element(app, "you.settings")
        for _ in 0..<6 where !settings.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "You has no Settings row")
        settings.tap()
        let category = IOSTest.element(app, "settings.category.integrations")
        for _ in 0..<4 where !category.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(category.waitForExistence(timeout: 20), "Settings has no Integrations")
        category.tap()
        let trakt = IOSTest.element(app, "settings.dest.trakt")
        XCTAssertTrue(trakt.waitForExistence(timeout: 20), "Integrations has no Trakt row")
        trakt.tap()
        XCTAssertTrue(IOSTest.element(app, "settings.trakt").waitForExistence(timeout: 20), "Trakt settings never opened")
    }

    private func connect(_ app: XCUIApplication) {
        let connect = IOSTest.element(app, "trakt.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 20), "Trakt offers no Connect")
        IOSTest.capture("01-trakt-before-connecting", in: self)
        connect.tap()
        let code = IOSTest.element(app, "trakt.code")
        XCTAssertTrue(code.waitForExistence(timeout: 20), "the connect sheet never showed the code")
        IOSTest.capture("02-trakt-code", in: self)
        let profile = IOSTest.element(app, "trakt.profile")
        XCTAssertTrue(profile.waitForExistence(timeout: 30), "the demo's approval never connected Trakt")
        IOSTest.settle(1)
        IOSTest.capture("03-trakt-connected", in: self)
    }

    /// With Trakt connected, Statistics counts everything Trakt knows: Everything adds the show and the two films watched on
    /// streaming services, while the plays Crucible sent to Trakt from the server are not counted twice; Plex goes back to the
    /// server's own history.
    func testStatisticsBringInEverythingTraktKnows() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        IOSTest.tab(app, "You").tap()
        IOSTest.tab(app, "You").tap()
        let statistics = IOSTest.element(app, "you.statistics")
        for _ in 0..<6 where !statistics.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(statistics.waitForExistence(timeout: 20), "You has no Statistics row")
        statistics.tap()
        let everything = app.buttons["stats.source.everything"]
        let plex = app.buttons["stats.source.plex"]
        XCTAssertTrue(everything.waitForExistence(timeout: 30), "Statistics offers no Everything with Trakt connected")
        plex.tap()
        IOSTest.settle(4)
        let plexShows = tile(app, "Shows")
        let plexMovies = tile(app, "Movies")
        IOSTest.capture("06-statistics-plex", in: self)
        everything.tap()
        XCTAssertTrue(IOSTest.wait(for: tileElement(app, "Shows"), "label CONTAINS ', \(plexShows + 1)'", timeout: 30), "Everything does not add the show watched elsewhere")
        XCTAssertEqual(tile(app, "Shows"), plexShows + 1, "a show partly watched elsewhere is still one show")
        XCTAssertEqual(tile(app, "Movies"), plexMovies + 2, "Everything adds the two films watched elsewhere")
        IOSTest.settle(1)
        IOSTest.capture("07-statistics-everything", in: self)
    }

    private func tileElement(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    /// The number a statistics tile shows, read from its VoiceOver label ("Shows, 23").
    private func tile(_ app: XCUIApplication, _ title: String) -> Int {
        let element = tileElement(app, title)
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Statistics shows no \(title) tile")
        let parts = element.label.components(separatedBy: ", ")
        return parts.count > 1 ? Int(parts[1].filter(\.isNumber)) ?? -1 : -1
    }

    func testConnectingShowsTheAccountAndWhatIsSent() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Demo Viewer")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 10), "the connected account is not named")
        XCTAssertTrue(IOSTest.element(app, "trakt.scrobble").exists, "Scrobble Playback is missing")
        XCTAssertTrue(IOSTest.element(app, "trakt.anotherApp").exists, "Another App Records My Plays is missing")
        IOSTest.element(app, "trakt.disconnect").tap()
        let confirm = app.sheets.buttons["Disconnect"].exists ? app.sheets.buttons["Disconnect"] : app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Disconnect asks nothing")
        confirm.tap()
        XCTAssertTrue(IOSTest.element(app, "trakt.connect").waitForExistence(timeout: 20), "disconnecting did not bring Connect back")
    }

    /// Trakt's score sits on the hero's meta line beside Plex's own rating, under its mark, instead of a strip of its own.
    func testAConnectedDetailPageShowsTraktBesidePlexsRatingAndCheckIn() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        IOSTest.tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("Halcyon")
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Halcyon")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no Halcyon")
        result.tap()
        let hero = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".*Trakt [0-9]+%.*")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "the hero's meta line has no Trakt score")
        XCTAssertFalse(app.staticTexts["Ratings"].exists, "the separate ratings strip is gone")
        IOSTest.settle(1)
        IOSTest.capture("04-detail-inline-ratings", in: self)

        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the detail has no More menu")
        more.tap()
        let checkIn = app.buttons["Check In"]
        XCTAssertTrue(checkIn.waitForExistence(timeout: 10), "More has no Check In")
        checkIn.tap()
        IOSTest.settle(1.2)
        IOSTest.capture("05-after-check-in", in: self)
        more.tap()
        let cancel = app.buttons["Cancel Check-In"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "a checked-in title does not offer Cancel Check-In")
        cancel.tap()
        IOSTest.settle(1.2)
        more.tap()
        XCTAssertTrue(app.buttons["Check In"].waitForExistence(timeout: 10), "cancelling did not bring Check In back")
        IOSTest.capture("05-checked-in", in: self)
    }

    // MARK: - Community

    private func openHalcyon(_ app: XCUIApplication) {
        IOSTest.tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("Halcyon")
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Halcyon")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no Halcyon")
        result.tap()
    }

    /// Scrolls the page until `element` is on screen and can be tapped.
    private func scroll(to element: XCUIElement, in app: XCUIApplication, limit: Int = 14) {
        for _ in 0..<limit where !(element.exists && element.isHittable) {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
    }

    private func firstCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'trakt.comment.' AND NOT identifier IN {'trakt.comment.like', 'trakt.comment.replies', 'trakt.comment.react', 'trakt.comment.more', 'trakt.comment.text', 'trakt.comment.author'}")).firstMatch
    }

    /// A connected detail page shows its community after Cast & Crew: Trakt's score with how its voters spread, who watches, what
    /// people loved and didn't, and the comments rail; a comment opens its thread, where a reaction and a reply land at once.
    func testATitlesCommunityShowsWhatPeopleSayAndTakesAReply() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        openHalcyon(app)
        let pulse = IOSTest.element(app, "trakt.community.pulse")
        scroll(to: pulse, in: app)
        XCTAssertTrue(pulse.waitForExistence(timeout: 30), "the detail page has no Community pulse")
        IOSTest.settle(1.2)
        IOSTest.capture("10-community-pulse", in: self)
        let sentiments = IOSTest.element(app, "trakt.community.sentiments")
        scroll(to: sentiments, in: app, limit: 4)
        XCTAssertTrue(sentiments.exists, "Halcyon has no What People Say")
        let card = firstCard(app)
        scroll(to: card, in: app, limit: 6)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the Community has no comment cards")
        IOSTest.settle(1)
        IOSTest.capture("11-community-comments", in: self)

        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        IOSTest.settle(1)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let thread = IOSTest.element(app, "trakt.thread")
        XCTAssertTrue(thread.waitForExistence(timeout: 20), "a comment card did not open its thread")
        let laugh = IOSTest.element(app, "trakt.reaction.laugh")
        XCTAssertTrue(laugh.waitForExistence(timeout: 20), "the thread has no reaction bar")
        IOSTest.settle(1.5)
        IOSTest.capture("12-thread", in: self)
        laugh.tap()
        XCTAssertTrue(IOSTest.wait(for: laugh, "selected == true", timeout: 10), "a reaction did not light up")

        let reply = IOSTest.element(app, "trakt.thread.reply")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the thread offers no Reply")
        reply.tap()
        let text = IOSTest.element(app, "trakt.composer.text")
        XCTAssertTrue(text.waitForExistence(timeout: 20), "Reply did not open the composer")
        XCTAssertTrue(IOSTest.element(app, "trakt.composer.rules").exists, "the composer does not show Trakt's rules the first time")
        let post = app.buttons["trakt.composer.post"]
        text.typeText("Too short")
        XCTAssertFalse(post.isEnabled, "a reply under five words can be posted")
        IOSTest.capture("13-composer-too-short", in: self)
        text.typeText(" to post, so here are more words")
        XCTAssertTrue(IOSTest.wait(for: post, "enabled == true", timeout: 5), "a reply of five words or more cannot be posted")
        IOSTest.capture("14-composer-ready", in: self)
        post.tap()
        let posted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "so here are more words")).firstMatch
        XCTAssertTrue(posted.waitForExistence(timeout: 20), "the posted reply is not in the thread")
        IOSTest.settle(1.5)
        IOSTest.capture("15-reply-posted", in: self)
    }

    /// See All lists every comment in the order picked; a review written there lands on top and its author opens their page.
    func testEveryCommentIsListedAndAReviewLandsOnTop() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        openHalcyon(app)
        let seeAll = IOSTest.element(app, "trakt.community.seeAll")
        scroll(to: seeAll, in: app, limit: 18)
        XCTAssertTrue(seeAll.waitForExistence(timeout: 30), "the Community has no See All")
        seeAll.tap()
        let list = IOSTest.element(app, "trakt.comments")
        XCTAssertTrue(list.waitForExistence(timeout: 20), "See All did not open the comments")
        XCTAssertTrue(firstCard(app).waitForExistence(timeout: 20), "the comments list is empty")
        IOSTest.settle(1.5)
        IOSTest.capture("20-all-comments", in: self)

        app.buttons["trakt.comments.sort"].tap()
        let newest = app.buttons["Newest"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "the sort menu has no Newest")
        newest.tap()
        IOSTest.settle(2)
        IOSTest.capture("21-newest", in: self)

        app.buttons["trakt.comments.write"].tap()
        let text = IOSTest.element(app, "trakt.composer.text")
        XCTAssertTrue(text.waitForExistence(timeout: 20), "Write a Review did not open the composer")
        let gotIt = IOSTest.element(app, "trakt.composer.rules.ok")
        if gotIt.exists { gotIt.tap() }
        app.buttons["trakt.composer.spoiler"].tap()
        text.typeText("A quiet film that grows on you long after the credits roll.")
        IOSTest.capture("22-composer-review", in: self)
        app.buttons["trakt.composer.post"].tap()
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "(You)")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 20), "the new comment is not listed as the viewer's")
        IOSTest.settle(1.5)
        IOSTest.capture("23-review-posted", in: self)

        let author = app.buttons.matching(NSPredicate(format: "identifier == 'trakt.comment.author' AND label != 'Demo Viewer'")).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), "no comment names its author")
        author.tap()
        let member = IOSTest.element(app, "trakt.member")
        XCTAssertTrue(member.waitForExistence(timeout: 20), "an author did not open their page")
        let follow = app.buttons["trakt.member.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 20), "a member's page has no Follow")
        IOSTest.settle(1.5)
        IOSTest.capture("24-member", in: self)
        follow.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN {'Following', 'Requested'}")).firstMatch.waitForExistence(timeout: 10), "Follow did not turn into Following")
    }
}

