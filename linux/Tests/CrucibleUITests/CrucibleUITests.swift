import Foundation
import Testing
@testable import CrucibleUI
@testable import Kiln

@MainActor
enum SharedGPU {
    static let gpu: GPU = {
        do { return try GPU(display: nil, surface: nil) } catch { fatalError("\(error)") }
    }()
}

@MainActor
@Suite(.serialized) struct TokenTests {
    @Test func deskIsTheTVLayoutAtSixtyPercent() {
        let desk = Metrics(density: .desk)
        let couch = Metrics(density: .couch)
        #expect(couch.posterSize == Size(width: 260, height: 390))
        #expect(desk.posterSize == Size(width: 156, height: 234))
        #expect(desk.gutter == 24)
        #expect(TypeScale(metrics: desk).body.size == 17.5)
        #expect(TypeScale(metrics: couch).headline.size == 38)
    }

    @Test func cardZoomScalesCardsButNotTheLayout() {
        let zoomed = Metrics(density: .desk, cardZoom: 1.25)
        #expect(zoomed.posterSize.width == 195)
        #expect(zoomed.gutter == 24)
        #expect(Metrics(density: .desk, cardZoom: 5).cardZoom == 1.6)
    }

    @Test func aGridAddsColumnsAsTheWindowWidens() {
        Theme.current.density = .desk
        let narrow = CardStyle.grid(aspect: 1.5, width: 1000)
        let wide = CardStyle.grid(aspect: 1.5, width: 2000)
        let metrics = Theme.current.metrics
        #expect(metrics.gridColumns(itemWidth: wide.itemWidth, width: 2000) > metrics.gridColumns(itemWidth: narrow.itemWidth, width: 1000))
        let columns = metrics.gridColumns(itemWidth: narrow.itemWidth, width: 1000)
        let used = Float(columns) * narrow.itemWidth + Float(columns - 1) * metrics.gutter
        #expect(used <= 1000 && used > 1000 - Float(columns))
    }

    @Test func landscapeGridCardsCoverAboutAPostersArea() {
        Theme.current.density = .couch
        defer { Theme.current.density = .desk }
        let style = CardStyle.grid(aspect: 9.0 / 16.0, width: 1760)
        #expect(style.kind == .backdrop)
        #expect(style.itemWidth > 260)
        #expect(abs(style.artworkSize.height - (style.itemWidth * 9 / 16).rounded()) < 1)
    }

    @Test func overlaysOnDarkColoursMatchSRGBBlending() {
        let shade = Color.shade(0.5)
        let blended = 1 - shade.alpha
        let srgbResult: Float = 0.5
        let linearOfSRGB = Float(pow(Double(srgbResult), 2.2))
        #expect(abs(blended - linearOfSRGB) < 0.01)
    }
}

@MainActor
@Suite(.serialized) struct ComponentTests {
    let window: Window

    init() throws {
        Theme.current.density = .desk
        window = try Window(offscreen: Size(width: 1280, height: 720), scale: 1, gpu: SharedGPU.gpu)
    }

    @Test func aShelfLaysOutItsCardsAndRemembersFocus() {
        let shelf = ShelfView(header: SectionHeader(title: "Continue Watching"), style: .poster)
        shelf.setItems((0..<12).map { CardItem(id: "\($0)", title: "Title \($0)") })
        window.contentView.addSubview(shelf)
        shelf.frame = Rect(x: 0, y: 0, width: 1280, height: shelf.preferredHeight)
        window.render()
        let metrics = Theme.current.metrics
        #expect(shelf.card(for: "0")?.frame.x == metrics.sideMargin)
        #expect(shelf.card(for: "1")?.frame.x == metrics.sideMargin + CardStyle.poster.itemWidth + metrics.gutter)
        #expect(shelf.scroller.contentLength > 1280)
        window.focus.setVisible(true)
        window.focus.focus(shelf, animated: false)
        #expect(window.focusedView === shelf.card(for: "0"))
        for _ in 0..<9 { window.handleKey(KeyEvent(key: .right)) }
        window.settle()
        #expect(window.focusedView === shelf.card(for: "9"))
        #expect(shelf.card(for: "9")!.frameInWindow.maxX <= 1280)
    }

    @Test func downFromAShelfLandsOnTheCardBelowNotTheNextShelfsSeeAll() {
        let first = ShelfView(header: SectionHeader(title: "Continue Watching"), style: .landscape)
        let second = ShelfView(header: SectionHeader(title: "Up Next", hasSeeAll: true), style: .landscape)
        first.setItems((0..<4).map { CardItem(id: "a\($0)", title: "A \($0)") })
        second.setItems((0..<4).map { CardItem(id: "b\($0)", title: "B \($0)") })
        window.contentView.addSubview(first)
        window.contentView.addSubview(second)
        first.frame = Rect(x: 0, y: 0, width: 1280, height: first.preferredHeight)
        second.frame = Rect(x: 0, y: first.preferredHeight, width: 1280, height: second.preferredHeight)
        window.render()
        window.focus.setVisible(true)
        window.focus.focus(first.card(for: "a0"), animated: false)
        window.handleKey(KeyEvent(key: .down))
        #expect(window.focusedView === second.card(for: "b0"))
        window.handleKey(KeyEvent(key: .up))
        #expect(window.focusedView !== first.card(for: "a0"))
        #expect(window.focusedView?.isDescendant(of: second) == true)
    }

    @Test func anAlertWithMoreButtonsThanFitScrollsThemInsideTheWindow() {
        let actions = (0..<30).map { AlertView.Action("Playlist \($0)") } + [AlertView.Action("Cancel", role: .cancel)]
        let alert = AlertView(title: "Add to Playlist", actions: actions)
        alert.present(in: window)
        window.settle()
        let panelBottom = alert.subviews.compactMap { $0 as? ScrollView }.first.map { $0.frameInWindow.maxY } ?? .infinity
        #expect(panelBottom <= 720)
        for _ in 0..<40 { window.handleKey(KeyEvent(key: .down)) }
        window.settle()
        let focused = window.focusedView?.frameInWindow ?? .zero
        #expect(focused.maxY <= 720 && focused.minY >= 0)
        #expect((window.focusedView as? ButtonView)?.title == "Cancel")
        alert.dismiss()
    }

    @Test func replacingItemsKeepsTheViewsOfItemsThatStay() {
        let shelf = ShelfView(header: nil, style: .poster)
        shelf.setItems([CardItem(id: "a", title: "A"), CardItem(id: "b", title: "B")])
        let kept = shelf.card(for: "b")
        shelf.setItems([CardItem(id: "b", title: "B renamed"), CardItem(id: "c", title: "C")])
        #expect(shelf.card(for: "b") === kept)
        #expect(kept?.item.title == "B renamed")
        #expect(shelf.card(for: "a") == nil)
    }

    @Test func theHeroGivesWayLineByLineWhenItRunsOutOfRoom() {
        let hero = HeroInfoView()
        window.contentView.addSubview(hero)
        let long = HeroInfo(eyebrow: "Continue Watching", title: "A Title Long Enough To Need Two Lines In The Hero Block Of Home",
                            metaParts: ["2024", "PG-13"], badges: ["4K"],
                            synopsis: String(repeating: "A sentence that keeps going and going across the column. ", count: 8))
        hero.frame = Rect(x: 0, y: 0, width: 540, height: 400)
        hero.configure(long, animated: false)
        window.render()
        hero.frame = Rect(x: 0, y: 0, width: 540, height: 120)
        window.render()
        #expect(window.capture().pixels.count > 0)
    }

    @Test func aButtonSizesToItsLabelAndActivatesOnEnter() {
        let button = ButtonView(style: .glass, title: "Trailer", symbol: "film")
        var presses = 0
        button.onPress = { presses += 1 }
        window.contentView.addSubview(button)
        let size = button.sizeThatFits(Size(width: 1000, height: 1000))
        #expect(size.height == Theme.current.metrics.primaryControlHeight)
        #expect(size.width > size.height)
        button.frame = Rect(origin: Point(x: 100, y: 100), size: size)
        window.focus.focus(button, animated: false)
        window.handleKey(KeyEvent(key: .return))
        #expect(presses == 1)
        window.handlePointerMoved(to: Point(x: 110, y: 110))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerButton(.primary, pressed: false)
        #expect(presses == 2)
    }

    @Test func aTextFieldEditsLikeADesktopField() {
        let field = TextFieldView(placeholder: "Search")
        var changes: [String] = []
        field.onChange = { changes.append($0) }
        field.frame = Rect(x: 0, y: 0, width: 600, height: 60)
        window.contentView.addSubview(field)
        window.focus.focus(field, animated: false)
        for character in "salt flats" { window.handleKey(KeyEvent(key: Key.character(character), text: String(character))) }
        #expect(field.text == "salt flats")
        window.handleKey(KeyEvent(key: .backspace, modifiers: .control))
        #expect(field.text == "salt ")
        window.handleKey(KeyEvent(key: .left))
        window.handleKey(KeyEvent(key: Key.character("y"), text: "y"))
        #expect(field.text == "saltY ".replacingOccurrences(of: "Y", with: "y"))
        window.handleKey(KeyEvent(key: Key.character("a"), text: "a", modifiers: .control))
        window.handleKey(KeyEvent(key: Key.character("x"), text: "x"))
        #expect(field.text == "x")
        window.handleKey(KeyEvent(key: .escape))
        #expect(field.text.isEmpty)
        #expect(changes.last == "")
        for character in "low tide now" { window.handleKey(KeyEvent(key: Key.character(character), text: String(character))) }
        window.handleKey(KeyEvent(key: .home))
        window.handleKey(KeyEvent(key: .right, modifiers: .control))
        window.handleKey(KeyEvent(key: .delete, modifiers: .control))
        #expect(field.text == "low now", "Ctrl+Right lands after a word and Ctrl+Delete takes the next one")
        window.render()
    }

    @Test func aTextFieldCopiesCutsAndPastesItsSelection() {
        let field = TextFieldView(placeholder: "Search")
        field.frame = Rect(x: 0, y: 0, width: 600, height: 60)
        window.contentView.addSubview(field)
        window.focus.focus(field, animated: false)
        for character in "salt flats" { window.handleKey(KeyEvent(key: Key.character(character), text: String(character))) }
        window.copy("before")
        window.handleKey(KeyEvent(key: Key.character("c"), modifiers: .control))
        #expect(window.pasteboardText() == "before", "Ctrl+C copies nothing until Ctrl+A selects")
        window.handleKey(KeyEvent(key: Key.character("a"), modifiers: .control))
        window.handleKey(KeyEvent(key: Key.character("x"), modifiers: .control))
        #expect(window.pasteboardText() == "salt flats")
        #expect(field.text.isEmpty)
        window.copy("  Low\r\nTide\t2  \n")
        window.handleKey(KeyEvent(key: Key.character("v"), modifiers: .control))
        #expect(field.text == "Low Tide 2", "a paste is one line, trimmed")
        window.handleKey(KeyEvent(key: .insert, modifiers: .shift))
        #expect(field.text == "Low Tide 2Low Tide 2")
        field.isSecure = true
        window.handleKey(KeyEvent(key: Key.character("a"), modifiers: .control))
        window.handleKey(KeyEvent(key: Key.character("c"), modifiers: .control))
        #expect(window.pasteboardText() == "  Low\r\nTide\t2  \n", "a secure field never copies")
        field.removeFromSuperview()
    }

    private func type(_ text: String) {
        for character in text { window.handleKey(KeyEvent(key: Key.character(character), text: String(character))) }
    }

    private func click(_ point: Point, count: Int = 1) {
        window.handlePointerMoved(to: point)
        for _ in 0..<count {
            window.handlePointerButton(.primary, pressed: true)
            window.handlePointerButton(.primary, pressed: false)
        }
    }

    @Test func aTextFieldSelectsWithShiftAndUndoesAWordAtATime() {
        let field = TextFieldView(placeholder: "Search")
        field.frame = Rect(x: 0, y: 0, width: 600, height: 60)
        window.contentView.addSubview(field)
        window.focus.focus(field, animated: false)
        type("hello world")
        for _ in 0..<5 { window.handleKey(KeyEvent(key: .left, modifiers: .shift)) }
        window.handleKey(KeyEvent(key: Key.character("c"), modifiers: .control))
        #expect(window.pasteboardText() == "world")
        type("there")
        #expect(field.text == "hello there")
        window.handleKey(KeyEvent(key: Key.character("z"), modifiers: .control))
        #expect(field.text == "hello world", "typing a word is one undo step")
        window.handleKey(KeyEvent(key: Key.character("z"), modifiers: [.control, .shift]))
        #expect(field.text == "hello there")
        window.handleKey(KeyEvent(key: .home, modifiers: .shift))
        window.handleKey(KeyEvent(key: .backspace))
        #expect(field.text.isEmpty)
        field.removeFromSuperview()
    }

    @Test func aClickPlacesTheCaretAndADoubleClickSelectsAWord() async {
        let field = TextFieldView(placeholder: "Search", symbol: nil)
        field.frame = Rect(x: 0, y: 200, width: 600, height: 60)
        window.contentView.addSubview(field)
        window.focus.focus(field, animated: false)
        type("salt flats")
        window.render()
        click(Point(x: field.frame.minX + Theme.current.metrics.controlInset + 20, y: field.frame.midY))
        type("X")
        #expect(field.text.first != "X" && field.text.last != "X" && field.text.contains("X"), "a click puts the caret under the pointer")
        window.handleKey(KeyEvent(key: Key.character("z"), modifiers: .control))
        try? await Task.sleep(for: .milliseconds(500))
        click(Point(x: field.frame.maxX - 120, y: field.frame.midY))
        type("!")
        #expect(field.text == "salt flats!", "a click past the text puts the caret at its end")
        try? await Task.sleep(for: .milliseconds(500))
        field.setText("salt flats", notify: false)
        window.render()
        click(Point(x: field.frame.minX + 15, y: field.frame.midY), count: 2)
        type("Pale")
        #expect(field.text == "Pale flats", "a double click selects the word under the pointer")
        field.removeFromSuperview()
    }

    @Test func aDestructiveConfirmationStartsOnCancelWithItsButtonsInARow() {
        AlertView.confirm(title: "Delete Playlist?", confirm: "Delete", in: window) {}
        window.settle()
        let alert = window.contentView.subviews.compactMap { $0 as? AlertView }.first
        #expect((window.focusedView as? ButtonView)?.title == "Cancel")
        let buttons = alert?.subviews.compactMap { $0 as? ScrollView }.first?.subviews.compactMap { $0 as? ButtonView } ?? []
        #expect(buttons.count == 2)
        #expect(Set(buttons.map { $0.frame.y }).count == 1, "on a desk the two buttons sit side by side")
        #expect(buttons.first { $0.title == "Cancel" }.map { $0.frame.minX } ?? 0 < buttons.first { $0.title == "Delete" }.map { $0.frame.minX } ?? 0)
        window.handleKey(KeyEvent(key: .escape))
    }

    @Test func aCardOffersPlayWatchedAndItsMenuUnderThePointer() {
        let grid = CardGridView()
        var played: [String] = []
        var toggled: [String] = []
        var menus: [String] = []
        grid.onPlay = { played.append($0.id); return true }
        grid.onToggleWatched = { toggled.append($0.id) }
        grid.onContextMenu = { card, _ in menus.append(card.id) }
        grid.setItems([CardItem(id: "a", title: "A Title Long Enough To Be Cut Short In One Line", subtitle: "2017")])
        grid.frame = Rect(x: 0, y: 0, width: 1280, height: 600)
        window.contentView.addSubview(grid)
        window.render()
        guard let card = grid.subviews.compactMap({ $0 as? CardView }).first else { Issue.record("no card"); return }
        let art = card.frameInWindow
        let artHeight = card.style.artworkSize.height
        window.handlePointerMoved(to: Point(x: art.midX, y: art.minY + artHeight / 2))
        window.settle()
        click(Point(x: art.midX, y: art.minY + artHeight / 2))
        #expect(played == ["a"])
        let inset = Theme.current.metrics.badgeInset + 6
        click(Point(x: art.minX + inset, y: art.minY + inset))
        #expect(toggled == ["a"])
        click(Point(x: art.maxX - inset, y: art.minY + inset))
        #expect(menus == ["a"])
        #expect(card.tooltip(at: Point(x: 4, y: artHeight + 12))?.contains("Cut Short") == true, "a title the caption cuts short shows whole")
        window.focus.focus(card, animated: false)
        window.handleKey(KeyEvent(key: .space, text: " "))
        #expect(played == ["a", "a"], "Space plays the focused card")
        grid.removeFromSuperview()
    }

    @Test func aDesktopScrollbarPagesOnAClickAndDragsItsThumb() {
        ScrollView.desktopScrollbars = true
        defer { ScrollView.desktopScrollbars = false }
        let scroller = ScrollView(axis: .vertical)
        scroller.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        scroller.contentLength = 1200
        window.contentView.addSubview(scroller)
        window.render()
        click(Point(x: 392, y: 280))
        window.settle()
        #expect(scroller.offset > 200, "a click below the thumb pages down")
        let before = scroller.offset
        let thumbStart = 4 + 217 * before / 900
        window.handlePointerMoved(to: Point(x: 392, y: thumbStart + 10))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerMoved(to: Point(x: 392, y: thumbStart + 60))
        window.handlePointerButton(.primary, pressed: false)
        #expect(scroller.offset > before + 150, "dragging the thumb scrolls")
        scroller.removeFromSuperview()
    }

    @Test func aTextEditorPastesLinesAsTheyAre() {
        let editor = TextEditorView(placeholder: "Comment")
        editor.frame = Rect(x: 0, y: 0, width: 600, height: 200)
        window.contentView.addSubview(editor)
        window.focus.focus(editor, animated: false)
        window.copy("First line\r\nSecond line")
        window.handleKey(KeyEvent(key: Key.character("v"), modifiers: .control))
        #expect(editor.text == "First line\nSecond line")
        window.handleKey(KeyEvent(key: Key.character("a"), modifiers: .control))
        window.handleKey(KeyEvent(key: Key.character("c"), modifiers: .control))
        #expect(window.pasteboardText() == "First line\nSecond line")
        editor.removeFromSuperview()
    }

    @Test func aTextFieldShowsACompositionUntilTheInputMethodCommitsIt() {
        let field = TextFieldView(placeholder: "Search")
        var changes: [String] = []
        field.onChange = { changes.append($0) }
        field.frame = Rect(x: 0, y: 0, width: 600, height: 60)
        window.contentView.addSubview(field)
        window.focus.focus(field, animated: false)
        #expect(window.textInputClient === field)
        for character in "ab" { window.handleKey(KeyEvent(key: Key.character(character), text: String(character))) }
        field.applyTextInput(TextInputEvent(preedit: "にほ", preeditCursor: 6..<6))
        #expect(field.text == "ab", "a composition is not text yet")
        window.render()
        field.applyTextInput(TextInputEvent(commit: "日本"))
        #expect(field.text == "ab日本")
        #expect(field.textInputState.cursor == "ab日本".utf8.count)
        window.handleKey(KeyEvent(key: Key.character("a"), modifiers: .control))
        field.applyTextInput(TextInputEvent(preedit: "x"))
        #expect(field.text.isEmpty, "a composition replaces the selection")
        field.isSecure = true
        #expect(field.textInputState.purpose == .password)
        #expect(changes == ["a", "ab", "ab日本", ""])
        field.removeFromSuperview()
    }

    @Test func aTextEditorTakesCommitsAcrossLines() {
        let editor = TextEditorView(placeholder: "Comment")
        editor.frame = Rect(x: 0, y: 0, width: 600, height: 200)
        window.contentView.addSubview(editor)
        window.focus.focus(editor, animated: false)
        editor.applyTextInput(TextInputEvent(preedit: "かんじ", preeditCursor: 9..<9))
        window.render()
        editor.applyTextInput(TextInputEvent(commit: "漢字\n二行目"))
        #expect(editor.text == "漢字\n二行目")
        #expect(editor.textInputState.multiline)
        editor.applyTextInput(TextInputEvent(commit: "", deleteBefore: "目".utf8.count))
        #expect(editor.text == "漢字\n二行")
        editor.removeFromSuperview()
    }

    @Test func aSynopsisSelectsWithThePointerAndCopiesWithControlC() {
        let synopsis = SynopsisView(text: "A retired salvage pilot is hired to find what its crew left behind.")
        let button = ButtonView(style: .glass, title: "Play")
        synopsis.frame = Rect(x: 0, y: 0, width: 1000, height: synopsis.sizeThatFits(Size(width: 1000, height: 1000)).height)
        button.frame = Rect(x: 0, y: 300, width: 160, height: 50)
        window.contentView.addSubview(synopsis)
        window.contentView.addSubview(button)
        window.focus.focus(button, animated: false)
        window.render()
        let margin = Theme.current.metrics.sideMargin
        window.handlePointerMoved(to: Point(x: margin + 4, y: 10))
        #expect(synopsis.cursor(at: Point(x: margin + 4, y: 10)) == .text)
        for _ in 0..<3 {
            window.handlePointerButton(.primary, pressed: true)
            window.handlePointerButton(.primary, pressed: false)
        }
        #expect(window.clickCount == 3)
        #expect(synopsis.selectedText == synopsis.text)
        window.copy("")
        window.handleKey(KeyEvent(key: Key.character("c"), modifiers: .control))
        #expect(window.pasteboardText() == synopsis.text, "Ctrl+C copies the selection while a button has the focus")
        window.handlePointerMoved(to: Point(x: 20, y: 320))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerButton(.primary, pressed: false)
        #expect(synopsis.selectedText == nil, "a press elsewhere clears the selection")
        synopsis.removeFromSuperview()
        button.removeFromSuperview()
    }

    @Test func aReadOnlyPanelIsAFocusStopOnlyWhileAScreenReaderListens() {
        let panel = ReadOnlyPanelView(frame: Rect(x: 0, y: 0, width: 300, height: 120))
        window.contentView.addSubview(panel)
        #expect(!panel.canBecomeFocused)
        window.simulatesScreenReader = true
        #expect(panel.canBecomeFocused)
        #expect(panel.accessibilityRole == .label)
        #expect(!panel.accessibilityExposesChildren)
        window.focus.focus(panel, animated: false)
        window.render()
        window.simulatesScreenReader = false
        panel.removeFromSuperview()
    }

    @Test func cardsReadTheirWatchStateAndMenuHint() {
        var item = CardItem(id: "a", title: "Halcyon", subtitle: "2021", progress: 0.45)
        #expect(item.spokenValue == "45 percent watched")
        item.progress = nil
        item.isWatched = true
        #expect(item.spokenValue == "Watched")
        let card = CardView(item: item, style: .poster)
        #expect(card.accessibilityLabel == "Halcyon, 2021")
        #expect(card.accessibilityHint == nil)
        card.onContextMenu = { _, _ in }
        #expect(card.accessibilityHint == "Press the Menu key for more options")
    }

    @Test func theHeroReadsAsOneSummary() {
        let hero = HeroInfoView()
        #expect(hero.accessibilityRole == .none)
        hero.configure(HeroInfo(eyebrow: "Movie", title: "Halcyon", metaParts: ["2021", "2 h 14 m"],
                                ratings: [HeroRating(mark: .star, text: "8.1", spoken: "IMDb 8.1")], badges: ["4K", "HDR10"], progress: 0.3),
                       animated: false)
        #expect(hero.accessibilityLabel == "Halcyon. Movie. 2021, 2 h 14 m, IMDb 8.1. 4K, HDR10")
        #expect(hero.accessibilityValue == "30 percent watched")
        hero.configure(HeroInfo(title: "Halcyon", spokenText: "Halcyon, movie, 2021"), animated: false)
        #expect(hero.accessibilityLabel == "Halcyon, movie, 2021")
    }

    @Test func closingAMenuOrAlertHandsFocusStraightBack() {
        let anchor = ButtonView(style: .glass, title: "Manage")
        let neighbour = ButtonView(style: .glass, title: "Neighbour")
        anchor.frame = Rect(x: 100, y: 100, width: 160, height: 50)
        neighbour.frame = Rect(x: 100, y: 200, width: 160, height: 50)
        window.contentView.addSubview(anchor)
        window.contentView.addSubview(neighbour)
        window.focus.setVisible(true)
        window.focus.focus(anchor, animated: false)
        var landed: [View] = []
        window.focus.onChange = { _, new in if let new { landed.append(new) } }
        defer { window.focus.onChange = nil }

        var chosen: String?
        let menu = MenuView(title: "Manage", items: [MenuView.Item(id: "refresh", title: "Refresh")], anchor: anchor.frameInWindow)
        menu.onSelect = { chosen = $0.id }
        menu.present(in: window)
        window.render()
        landed.removeAll()
        window.handleKey(KeyEvent(key: .return))
        #expect(chosen == "refresh")
        #expect(landed.count == 1 && landed.first === anchor, "focus goes from the menu to its button without passing a neighbour")

        AlertView.notice(title: "Sent", in: window)
        window.render()
        landed.removeAll()
        window.handleKey(KeyEvent(key: .return))
        #expect(landed.count == 1 && landed.first === anchor, "focus goes from the alert to the button without passing a neighbour")
        #expect(window.focusedView === anchor)
    }

    @Test func aTabBarSelectsWithThePointer() {
        let bar = TabBarView()
        bar.tabs = [.init(id: "home", title: "Home"), .init(id: "movies", title: "Movies")]
        bar.select("home", animated: false)
        var chosen: String?
        bar.onSelect = { chosen = $0.id }
        bar.frame = Rect(x: 0, y: 0, width: 1280, height: 100)
        window.contentView.addSubview(bar)
        window.render()
        let movies = bar.subviews.last!.frameInWindow
        window.handlePointerMoved(to: Point(x: movies.midX, y: movies.midY))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerButton(.primary, pressed: false)
        #expect(chosen == "movies")
        #expect(bar.selectedID == "movies")
    }

    /// A menu with an action, a stepper, a submenu with choices and a closing action, values held in `state`.
    private final class MenuState {
        var value = 0
        var choice = "a"
        var ran: [String] = []
    }

    private func contextMenu(_ state: MenuState) -> ContextMenuView {
        ContextMenuView(at: Point(x: 100, y: 100)) {
            [
                .action(ContextMenuView.Action("Play") { state.ran.append("play") }),
                .separator,
                .stepper(ContextMenuView.Stepper("Sync", value: "\(state.value)", decrease: { state.value -= 1 }, increase: { state.value += 1 },
                                                 reset: { state.value = 0 })),
                .submenu("Shape", detail: state.choice) {
                    ["a", "b", "c"].map { name in
                        .action(ContextMenuView.Action(name, isChecked: state.choice == name) { state.choice = name })
                    }
                },
                .action(ContextMenuView.Action("Close") { state.ran.append("close") }),
            ]
        }
    }

    @Test func aContextMenuStepsAValueInPlaceAndStaysOpen() {
        let state = MenuState()
        let menu = contextMenu(state)
        menu.present(in: window)
        window.settle()
        #expect((window.focusedView as? ContextMenuRow)?.accessibilityLabel == "Play")
        window.handleKey(KeyEvent(key: .down))
        #expect((window.focusedView as? ContextMenuRow)?.accessibilityLabel == "Sync")
        window.handleKey(KeyEvent(key: .right))
        window.handleKey(KeyEvent(key: .right))
        window.handleKey(KeyEvent(key: .left))
        #expect(state.value == 1)
        #expect(menu.superview != nil)
        #expect((window.focusedView as? ContextMenuRow)?.accessibilityValue == "1")
        window.handleKey(KeyEvent(key: .return))
        #expect(state.value == 0)
        menu.dismiss()
    }

    @Test func aContextMenuSubmenuOpensBesideItsRowAndKeepsItsPlaceWhenValuesChange() {
        let state = MenuState()
        let menu = contextMenu(state)
        menu.present(in: window)
        window.settle()
        window.handleKey(KeyEvent(key: .down))
        window.handleKey(KeyEvent(key: .right))
        window.handleKey(KeyEvent(key: .down))
        #expect((window.focusedView as? ContextMenuRow)?.accessibilityLabel == "Shape")
        window.handleKey(KeyEvent(key: .right))
        window.settle()
        let panels = menu.subviews.compactMap { $0 as? ContextMenuPanel }
        #expect(panels.count == 2)
        #expect((window.focusedView as? ContextMenuRow)?.accessibilityLabel == "a")
        let shapeRow = panels[0].rows.first { $0.accessibilityLabel == "Shape" }
        #expect(panels[1].frame.minX >= (shapeRow?.frameInWindow.maxX ?? 0) - 20)
        menu.reloadAll()
        let rebuiltShape = menu.subviews.compactMap { $0 as? ContextMenuPanel }[0].rows.first { $0.accessibilityLabel == "Shape" }
        #expect(panels[1].opener === rebuiltShape)
        window.handleKey(KeyEvent(key: .down))
        window.handleKey(KeyEvent(key: .return))
        #expect(state.choice == "b")
        #expect(menu.superview == nil)
    }

    @Test func leftAndEscapeCloseASubmenuBeforeTheMenu() {
        let state = MenuState()
        let menu = contextMenu(state)
        menu.present(in: window)
        window.settle()
        window.handleKey(KeyEvent(key: .down))
        window.handleKey(KeyEvent(key: .down))
        window.handleKey(KeyEvent(key: .right))
        #expect(menu.subviews.compactMap { $0 as? ContextMenuPanel }.count == 2)
        window.handleKey(KeyEvent(key: .left))
        #expect(menu.subviews.compactMap { $0 as? ContextMenuPanel }.count == 1)
        #expect((window.focusedView as? ContextMenuRow)?.accessibilityLabel == "Shape")
        window.handleKey(KeyEvent(key: .right))
        window.handleKey(KeyEvent(key: .escape))
        #expect(menu.subviews.compactMap { $0 as? ContextMenuPanel }.count == 1)
        window.handleKey(KeyEvent(key: .escape))
        #expect(menu.superview == nil)
        #expect(state.ran.isEmpty)
    }

    private func lit(_ panel: ContextMenuPanel) -> [String] {
        panel.rows.filter { panel.highlighted === $0 }.compactMap(\.accessibilityLabel)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func centre(_ label: String, in menu: ContextMenuView, panel index: Int = 0) -> Point {
        let row = menu.panels[index].rows.first { $0.accessibilityLabel == label }!
        let frame = row.frameInWindow
        return Point(x: frame.midX, y: frame.midY)
    }

    @Test func aPanelHighlightsOneRowWhereverThePointerAndKeyboardWent() async throws {
        let state = MenuState()
        let menu = contextMenu(state)
        menu.present(in: window)
        window.settle()
        window.handlePointerMoved(to: centre("Shape", in: menu))
        await wait(ContextMenuView.hoverDelay + 0.15)
        try #require(menu.panels.count == 2)
        #expect(lit(menu.panels[0]) == ["Shape"])
        window.handlePointerMoved(to: centre("Sync", in: menu))
        #expect(lit(menu.panels[0]) == ["Sync"])
        await wait(ContextMenuView.hoverDelay + 0.15)
        #expect(menu.panels.count == 1)
        window.handlePointerMoved(to: centre("Play", in: menu))
        window.handleKey(KeyEvent(key: .down))
        #expect(lit(menu.panels[0]) == ["Sync"])
        window.handleKey(KeyEvent(key: .down))
        window.handleKey(KeyEvent(key: .right))
        #expect(menu.panels.count == 2)
        #expect(lit(menu.panels[0]) == ["Shape"])
        window.handleKey(KeyEvent(key: .left))
        window.handleKey(KeyEvent(key: .down))
        #expect(lit(menu.panels[0]) == ["Close"])
        menu.dismiss()
    }

    @Test func aPointerHeadingIntoASubmenuMayCrossTheRowsOnItsWay() async throws {
        let state = MenuState()
        let menu = contextMenu(state)
        menu.present(in: window)
        window.settle()
        let shape = centre("Shape", in: menu)
        window.handlePointerMoved(to: shape)
        await wait(ContextMenuView.hoverDelay + 0.15)
        #expect(menu.panels.count == 2)
        let close = centre("Close", in: menu)
        let edge = menu.panels[1].frame.minX
        let target = Point(x: edge - 6, y: close.y)
        for step in 1...4 {
            let t = Float(step) / 4
            window.handlePointerMoved(to: Point(x: shape.x + (target.x - shape.x) * t, y: shape.y + (target.y - shape.y) * t))
        }
        #expect(lit(menu.panels[0]) == ["Shape"])
        await wait(0.1)
        #expect(menu.panels.count == 2)
        await wait(ContextMenuView.aimDelay + ContextMenuView.hoverDelay + 0.15)
        #expect(lit(menu.panels[0]) == ["Close"])
        #expect(menu.panels.count == 1)
        menu.dismiss()
    }

    @Test func theKeyboardWrapsJumpsAndTypesAhead() {
        let state = MenuState()
        let menu = contextMenu(state)
        menu.present(in: window)
        window.settle()
        window.handleKey(KeyEvent(key: .up))
        #expect(lit(menu.panels[0]) == ["Close"])
        window.handleKey(KeyEvent(key: .down))
        #expect(lit(menu.panels[0]) == ["Play"])
        window.handleKey(KeyEvent(key: .end))
        #expect(lit(menu.panels[0]) == ["Close"])
        window.handleKey(KeyEvent(key: .home))
        window.handleKey(KeyEvent(key: .character("s"), text: "s"))
        #expect(lit(menu.panels[0]) == ["Sync"])
        window.handleKey(KeyEvent(key: .character("h"), text: "h"))
        #expect(lit(menu.panels[0]) == ["Shape"])
        menu.dismiss()
    }

    @Test func aMenuThePointerOpenedStartsUnlitAndDownLandsOnTheFirstRow() {
        let state = MenuState()
        let menu = ContextMenuView(at: Point(x: 100, y: 100), highlightingFirstRow: false) {
            [.action(ContextMenuView.Action("Play") { state.ran.append("play") }), .action(ContextMenuView.Action("Close") { state.ran.append("close") })]
        }
        menu.present(in: window)
        window.settle()
        #expect(lit(menu.panels[0]).isEmpty)
        window.handleKey(KeyEvent(key: .return))
        #expect(state.ran.isEmpty)
        window.handleKey(KeyEvent(key: .down))
        #expect(lit(menu.panels[0]) == ["Play"])
        window.handleKey(KeyEvent(key: .return))
        #expect(state.ran == ["play"])
        #expect(menu.superview == nil)
    }

    @Test func aDropdownOnADeskHangsBelowItsButtonWithTheChosenRowLit() {
        var chosen: String?
        let button = Rect(x: 300, y: 200, width: 260, height: 40)
        let menu = MenuView(title: "Sort", items: [MenuView.Item(id: "title", title: "Title"), MenuView.Item(id: "year", title: "Year", isChecked: true)],
                            anchor: button)
        menu.onSelect = { chosen = $0.id }
        menu.present(in: window)
        window.settle()
        let desk = window.contentView.subviews.compactMap { $0 as? ContextMenuView }.first
        #expect(desk != nil)
        let panel = desk?.panels.first
        #expect(panel.map { $0.frame.minY >= button.maxY && $0.frame.width >= button.width } == true)
        #expect(panel.map(lit) == ["Year"])
        window.handleKey(KeyEvent(key: .up))
        window.handleKey(KeyEvent(key: .return))
        #expect(chosen == "title")
        #expect(menu.superview == nil)
    }
}
