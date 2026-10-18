Vendored from https://github.com/MathisP75/daemon-kde-mk2 (GPL-3.0, see LICENSE)
Commit: 01bf4df4666e9021ac8013bc2c4eaabc8d312d68   (2026-06-30)
Only the parts install.sh uses are kept. Not vendored: the upstream install.sh (LLM-written, Arch-only,
downloads nine third-party widgets), node_modules, GTK/Firefox/Kitty/IntelliJ themes, the WIP
global theme, screenshots, zips and the icon pack's four svg-color-change.sh dev helpers.
Icon pack adapted by upstream from Simply Circles (ju1464); see icons/Daemon-Icons/CREDITS and LICENSE.
Fonts (../fonts): Rajdhani and Orbitron, SIL OFL 1.1, from github.com/google/fonts.
VS Code (added 2026-09-23): upstream/vscode/ holds the author's packaged daemon-2-0-0.0.1.vsix (Oct 2024)
and the newer themes/Daemon-2.0-color-theme.json from the repo (maroon editor background, title bar and
menu colors). ../vscode/daemon-2-0.vsix is that vsix repacked with the newer theme file; it is what
install.sh installs.
