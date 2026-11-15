#!/usr/bin/env python3
"""Cuts static Inter fonts out of the bundled variable font: Text (opsz 14) and Display (opsz 32) in every weight Kiln
uses. Cairo re-applies a variable font's coordinates each time text switches between instances, which made every label
cost half a millisecond; static faces each keep their own FreeType face. Run from the repository root."""

import pathlib

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

FONTS = pathlib.Path("linux/Sources/Kiln/Resources/Fonts")
WEIGHTS = {400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold"}
CUTS = {"Kiln Inter": 14, "Kiln Inter Display": 32}


def rename(font: TTFont, family: str, style: str) -> None:
    """Names the instance as its own family so fontconfig matches it by family and weight."""
    names = font["name"]
    full = f"{family} {style}"
    postscript = f"{family.replace(' ', '')}-{style}"
    for record in list(names.names):
        if record.nameID in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
            names.removeNames(nameID=record.nameID)
    for name_id, value in ((1, family), (2, "Regular"), (3, postscript), (4, full), (6, postscript), (16, family), (17, style)):
        names.setName(value, name_id, 3, 1, 0x409)
    if style != "Regular":
        names.setName(full, 1, 3, 1, 0x409)
        names.setName("Regular", 2, 3, 1, 0x409)
    font["OS/2"].fsSelection = (font["OS/2"].fsSelection & ~0b1100001) | (0b1000000 if style == "Regular" else 0)


def main() -> None:
    source = FONTS / "InterVariable.ttf"
    for family, optical in CUTS.items():
        for weight, style in WEIGHTS.items():
            font = instancer.instantiateVariableFont(TTFont(source), {"wght": weight, "opsz": optical})
            rename(font, family, style)
            font["OS/2"].usWeightClass = weight
            target = FONTS / f"{family.replace(' ', '')}-{style}.ttf"
            font.save(target)
            print(target, target.stat().st_size)


if __name__ == "__main__":
    main()
