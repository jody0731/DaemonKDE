#!/usr/bin/env python3
"""Build daemon-2-0.vsix: the author's Daemon-2.0 VS Code theme with overrides.jsonc applied, plus
a generated light variant "Daemon-2.0 Light" in the same extension.

    python3 build.py

Inputs: ../upstream/vscode/daemon-2-0-0.0.1.vsix (package skeleton),
        ../upstream/vscode/themes/Daemon-2.0-color-theme.json (newest theme, JSONC),
        overrides.jsonc (colors to replace or add, dark),
        ../light/palette.py + overrides-light.jsonc (the light theme is the dark one, overrides
        included, run through the light palette, then overrides-light.jsonc on top).
Output: daemon-2-0.vsix next to this file. Label "Daemon-2.0" and extension ID stay the same, so the
installed setting and uninstall records keep working.
"""
import json
import os
import re
import sys
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
UP = os.path.join(HERE, "..", "upstream", "vscode")
sys.path.insert(0, os.path.join(HERE, "..", "light"))
import palette as P  # noqa: E402

THEME_IN_VSIX = "extension/themes/Daemon-2.0-color-theme.json"
LIGHT_IN_VSIX = "extension/themes/Daemon-2.0-Light-color-theme.json"
PACKAGE_IN_VSIX = "extension/package.json"
# in VS Code the cyan is text as well as lines, so it becomes a dark teal that reads as text
LIGHT_EXTRA = {"#5df4fe": P.CY_DEEP, "#00ffff": P.CY_DEEP, "#355d65": P.CY_PALE, "#ff5048": P.RD_TEXT,
               "#eeffff": P.INK, "#ffffff": P.INK, "#bbbbbb": P.INK_SOFT, "#b2ccd6": "#3d5a66"}


def lighten(theme):
    def walk(v):
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, str) and P.HEX.fullmatch(v):
            return P.light(v, LIGHT_EXTRA)
        return v
    out = walk(theme)
    out["name"], out["type"] = "Daemon-2.0 Light", "light"
    return out


def load_jsonc(path):
    text = open(path, encoding="utf-8").read()
    out, i, n = [], 0, len(text)
    while i < n:  # drop // and /* */ comments outside strings
        c = text[i]
        if c == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1]); i = j + 1
        elif text.startswith("//", i):
            i = text.find("\n", i) if "\n" in text[i:] else n
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        else:
            out.append(c); i += 1
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))


def main():
    theme = load_jsonc(os.path.join(UP, "themes", "Daemon-2.0-color-theme.json"))
    overrides = load_jsonc(os.path.join(HERE, "overrides.jsonc"))
    theme.setdefault("colors", {}).update(overrides)
    light = lighten(theme)
    light_overrides = load_jsonc(os.path.join(HERE, "overrides-light.jsonc"))
    light["colors"].update(light_overrides)
    dump = lambda t: (json.dumps(t, indent="\t", ensure_ascii=False) + "\n").encode()  # noqa: E731
    out = os.path.join(HERE, "daemon-2-0.vsix")
    with zipfile.ZipFile(os.path.join(UP, "daemon-2-0-0.0.1.vsix")) as src, \
         zipfile.ZipFile(out + ".tmp", "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            if item.filename == THEME_IN_VSIX:
                data = dump(theme)
            elif item.filename == PACKAGE_IN_VSIX:
                pkg = json.loads(src.read(item))
                pkg["description"] = "A Cyberpunk 2077 inspired theme, dark and light."
                pkg["contributes"]["themes"] = [
                    {"label": "Daemon-2.0", "uiTheme": "vs-dark", "path": "./themes/Daemon-2.0-color-theme.json"},
                    {"label": "Daemon-2.0 Light", "uiTheme": "vs", "path": "./themes/Daemon-2.0-Light-color-theme.json"},
                ]
                pkg.pop("__metadata", None)
                data = dump(pkg)
            else:
                data = src.read(item)
            dst.writestr(item, data)
        light_item = zipfile.ZipInfo(LIGHT_IN_VSIX, date_time=src.getinfo(THEME_IN_VSIX).date_time)
        light_item.compress_type = zipfile.ZIP_DEFLATED
        dst.writestr(light_item, dump(light))
    os.replace(out + ".tmp", out)
    print(f"{out}: dark {len(theme['colors'])} colors ({len(overrides)} overridden), "
          f"light {len(light['colors'])} colors ({len(light_overrides)} hand-set)")


if __name__ == "__main__":
    main()
