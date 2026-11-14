#!/usr/bin/env python3
"""Assemble the Apple TV store set from a UI test run: the ten panels are raw 4K captures, taken by the tests below.

Usage: marketing/store/tv_set.py UI_DIR [DEST]

UI_DIR holds one folder per test with its screenshot attachments, as `tv/scripts/arrange_attachments.py` (and so
`tv.sh uitest`) writes them; DEST defaults to marketing/appstore/tvos, where `scripts/asc-screenshots.py --only=tvos`
uploads from. Run the tests on an Apple TV 4K simulator at 4K (`TV_SIM_TYPE`), or the panels are not 3840 by 2160.

Two traps of a simulator that is not fresh or is too fresh: run `TourTests/testDeepLinksOpenTheRealDetailOnHomeAndTheRealPlayer`
alone first so the "Open in Crucible?" prompt is answered once, and uninstall the app before the Essentials test, which
is offered only once per install.
"""
import os
import sys

from PIL import Image

PANELS = [
    ("DemoTests.testEnteringShowsTheIntroThenAPopulatedHome", "04-home"),
    ("DemoTests.testWhatToWatchAnswersItsExamplesFromPreparedPicks", "watch-picks"),
    ("DemoTests.testAShowStartedInTheDemoWritesItsPreparedRecap", "recap"),
    ("DemoTests.testPaperLanternsOffersEssentialsOnceAndSkipsItsAnimeOnlyEpisodes", "17-essentials-offer"),
    ("DetailTests.testMovieDetailDark", "01-movie-primary-focused"),
    ("HomeTests.testLongPressMenuOffersCardActions", "11-long-press-menu-continue-watching"),
    ("LibraryTests.testMovieLibraryLoadedFiltersAndMenus", "01-loaded-first-recent-focused"),
    ("PlayerTests.testScrubbingWithLongPressRight", "01-scrubbed-forward"),
    ("PlayerTests.testUpNextProposalAtTheCreditsAndAcceptingStartsTheNextEpisode", "02-up-next-proposal"),
    ("DemoTests.testStatisticsHasEveryRangeUnlocked", "10-statistics"),
]
SIZE = (3840, 2160)
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    ui = sys.argv[1]
    dest = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "marketing/appstore/tvos")
    sources = [os.path.join(ui, test, name + ".png") for test, name in PANELS]
    problems = [f"missing {path}" for path in sources if not os.path.exists(path)]
    problems += [f"{path} is {Image.open(path).size}, not {SIZE}" for path in sources if os.path.exists(path) and Image.open(path).size != SIZE]
    if problems:
        sys.exit("\n".join(problems))
    os.makedirs(dest, exist_ok=True)
    for number, path in enumerate(sources, 1):
        Image.open(path).convert("RGB").save(os.path.join(dest, f"{number:02d}.png"))
        print(f"{number:02d}.png  {os.path.relpath(path, ui)}")


if __name__ == "__main__":
    main()
