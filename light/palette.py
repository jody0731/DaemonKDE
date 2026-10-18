"""The Daemon 2.0 Light palette: how every color of the dark theme maps to the light one.

Goal: the same cyberpunk identity (red frames, cyan accents, angular shapes) on pure white, written
for eyes with astigmatism, where light text on a dark background blurs and haloes. Three families,
each in graded steps, and nothing else:
  - white and neutral greys: #ffffff surfaces like the Claude app's light theme, greys with no warm
    (pink or yellow) cast, near-black ink text (about 16:1 on white);
  - true red (hue ~357, almost no blue) for frames and the title bar. Pale reds read as pink, so red
    is only ever used saturated; pale fills are grey or cyan;
  - bright cyan, from a pale selection tint to a deep text-level cyan.

`light(hex)` returns the light color for a dark-theme color: first the explicit table below
(the theme's own palette), then a fallback that follows the same rules for anything else.
"""
import colorsys
import re

# white and neutral greys (a hair cool, never warm)
WHITE = "#ffffff"      # windows, views, Konsole (was the maroon #210e15 and #040a10)
G1 = "#f6f7f8"         # alternate rows, headers
G2 = "#eef0f2"         # buttons, inactive title bar
G3 = "#e2e5e8"         # pressed / hover fills, grooves
G4 = "#cfd4d9"         # borders
G5 = "#a9b0b7"         # dark lines, disabled frames
G6 = "#7a838c"         # disabled text
INK = "#0e1d22"        # all text (was the neon cyan #5df4fe), 16:1 on white
INK_SOFT = "#4b5960"   # inactive / secondary text, 7:1

# cyan, pale to deep (hue ~185)
CY_TINT = "#e8fafc"    # hover, inactive selection
CY_PALE = "#c9f2f6"    # selection background
CY_LIGHT = "#7fe3ec"
CY_BRIGHT = "#14c8d6"  # large fills (progress, active markers)
CY = "#00aebc"         # lines, frames, focus (was #5df4fe as a line color)
CY_ICON = "#009aa8"    # icon glyphs, 3:1 on white
CY_TEXT = "#007c87"    # cyan as text, 4.9:1
CY_DEEP = "#005a63"

# true red, bright to deep (hue ~357)
RD_LIGHT = "#f2454c"   # softer red lines (was the coral #f4676b)
RD = "#e3121f"         # frames, title bar (was #ff5048 / #fb3048)
RD_TEXT = "#c40f1a"    # red as text, 5.9:1
RD_DEEP = "#990b14"

# role names used by build.py and vscode/build.py
PAPER = WHITE          # window background
PAPER_HI = WHITE       # views, text fields
PAPER_LO = G2          # headers, alternate surfaces
TEAL = CY
TEAL_PALE = CY_PALE
RED = RD
TITLE = RD             # window title bar
TITLE_TEXT = WHITE     # title text and button outlines on it (4.8:1 on RD)

MAP = {
    # neon cyan family -> bright cyan
    "#5df4fe": CY, "#5df2ff": CY, "#5cf2fc": CY, "#5beedc": "#00a99a", "#5aeedc": "#00a99a",
    "#00ffff": CY, "#0ff": CY,
    # reds -> true reds
    "#ff5048": RD, "#fb3048": RD, "#ff0000": "#d9001a", "#ff2155": "#d6102a", "#fa1e4e": "#d6102a",
    "#f4676b": RD_LIGHT, "#f56c6b": RD_LIGHT, "#f46a6e": RD_LIGHT, "#ff2a2a": "#e01b1b",
    "#710100": G3,          # dark-red bars and pressed items -> a grey fill, never a rose tint
    # dark surfaces -> white and neutral greys
    "#210e15": WHITE, "#200d14": WHITE, "#040a10": WHITE, "#0c1217": WHITE, "#351117": WHITE,
    "#331319": G2, "#14101f": G1, "#272932": G3, "#1e1e1e": G4, "#1c1c1c": G1,
    "#0d0b16": "#eef1f4", "#070d1a": TITLE_TEXT, "#162429": "#dff6f8", "#274047": "#a6e3ea",
    "#131d23": "#eef7f8", "#0d151a": G1, "#111314": G2, "#232629": G2, "#31363b": G4,
    "#141518": G2, "#1a1c1e": G3, "#0f1027": G2, "#262626": G3,
    # other neon accents -> deeper, same hue; the pink accent joins the reds
    "#fdf500": "#a58a00", "#28c775": "#13985a", "#1ac5b0": "#00a08e", "#cb1dcd": "#b01fb2",
    "#e455ae": RD_TEXT, "#9370db": "#5b3fb0", "#ff00ff": "#a3239f", "#f0f": "#a3239f",
    # greys used for disabled / muted parts
    "#636363": G5, "#666666": G6, "#666": G6, "#5f5f5f": G5, "#5a5a5a": G5,
    "#d1c5c0": INK, "#a0a0a0": G6,
}


def _rgb(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def _hex(r, g, b):
    return "#%02x%02x%02x" % tuple(round(max(0, min(1, v)) * 255) for v in (r, g, b))


def luminance(h):
    def lin(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in _rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def _cyan(hue):
    return 0.45 <= hue <= 0.56


def _red(hue):
    return hue >= 0.9 or hue <= 0.04


def fallback(h):
    """A color not in MAP: dark ones (backgrounds) become near-white, bright ones become deep.
    Pale results keep a tint only if cyan; reds are pulled to a true red hue."""
    r, g, b = _rgb(h)
    hue, lig, sat = colorsys.rgb_to_hls(r, g, b)
    if lig <= 0.35:                         # a dark surface -> a pale neutral one
        lig2 = 0.975 - lig * 0.55
        sat2 = min(sat, 0.35) if _cyan(hue) else min(sat, 0.05)
        if not _cyan(hue):
            hue = 0.58                      # the faint cast of the greys above
    else:                                   # text or an accent -> dark enough to read on white
        lig2, sat2 = max(0.22, 0.46 - (lig - 0.35) * 0.55), sat
        if _red(hue) and sat > 0.4:
            hue, sat2 = 0.993, max(sat, 0.85)
    return _hex(*colorsys.hls_to_rgb(hue, lig2, sat2))


def light(h, extra=None):
    """Light-theme color for a dark-theme #rgb / #rrggbb (an alpha suffix #rrggbbaa is kept)."""
    low = h.lower()
    alpha = ""
    if len(low) == 9:
        low, alpha = low[:7], low[7:]
    table = dict(MAP, **(extra or {}))
    if low in table:
        out = table[low]
    elif low in ("#ffffff", "#fff", "#000000", "#000"):
        out = low                           # white masks and black shadows stay as they are
    else:
        out = fallback(low)
    return out + alpha


HEX = re.compile(r"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")


def recolor_text(text, extra=None):
    """Replace every hex color in an SVG / CSS / config text."""
    return HEX.sub(lambda m: light(m.group(0), extra), text)


if __name__ == "__main__":   # python3 light/palette.py : contrast of each step on white
    for name in ("INK", "INK_SOFT", "G6", "G5", "CY", "CY_ICON", "CY_TEXT", "CY_DEEP", "RD_LIGHT", "RD", "RD_TEXT"):
        print(f"{name:9} {globals()[name]}  {contrast(globals()[name], WHITE):5.2f}:1 on white")
    print(f"title text on the red bar: {contrast(TITLE_TEXT, TITLE):.2f}:1 (white would be {contrast(WHITE, TITLE):.2f}:1)")
