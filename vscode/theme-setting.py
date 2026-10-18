#!/usr/bin/env python3
"""Read or change one string or true/false setting in VS Code's settings.json without reformatting it.

    theme-setting.py [--key KEY] FILE get          prints the current value, or __UNSET__
    theme-setting.py [--key KEY] FILE set VALUE    sets it (adds the key if missing, creates the file)
    theme-setting.py [--key KEY] FILE unset        removes the key
KEY defaults to workbench.colorTheme. The values true and false are written as JSON booleans
(and read back as the words true / false), everything else as a string.

settings.json is JSONC (comments, trailing commas), so this edits the text of the one key
instead of loading and re-dumping the file.
"""
import json
import os
import re
import sys

KEY = "workbench.colorTheme"
NOVAL = "__UNSET__"
if len(sys.argv) > 2 and sys.argv[1] == "--key":
    KEY = sys.argv[2]
    del sys.argv[1:3]
PAIR = re.compile(r'(?P<indent>[ \t]*)"' + re.escape(KEY) + r'"\s*:\s*(?P<val>"(?:[^"\\]|\\.)*"|true|false)\s*(?P<comma>,?)[ \t]*\r?\n?')


def main() -> int:
    path, op = sys.argv[1], sys.argv[2]
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    m = PAIR.search(text)
    if op == "get":
        v = json.loads(m.group("val")) if m else NOVAL
        print(v if isinstance(v, str) else json.dumps(v))
        return 0
    if op == "set":
        new = sys.argv[3] if sys.argv[3] in ("true", "false") else json.dumps(sys.argv[3])
        if m:
            text = text[:m.start("val")] + new + text[m.end("val"):]
        elif text.strip() in ("", "{}") or re.fullmatch(r"\s*\{\s*\}\s*", text):
            text = "{\n    \"%s\": %s\n}\n" % (KEY, new)
        else:
            brace = text.index("{") + 1
            rest = text[brace:]
            needs_comma = re.search(r'\S', re.sub(r'//[^\n]*|/\*.*?\*/', '', rest, flags=re.S)).group() != "}"
            text = text[:brace] + "\n    \"%s\": %s%s" % (KEY, new, "," if needs_comma else "") + rest
    elif op == "unset":
        if not m:
            return 0
        text = text[:m.start()] + text[m.end():]
    else:
        print("unknown operation " + op, file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".daemon-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
