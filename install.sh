#!/usr/bin/env bash
# Install the Daemon 2.0 KDE theme for the current user: both variants, Daemon 2.0 (dark) and
# Daemon 2.0 Light, each as a global theme in System Settings > Global Theme, set up as the light/dark
# pair for Plasma's day/night switching. Light is applied. No sudo: everything goes under
# ~/.local/share and ~/.config.
#   bash install.sh [options]        then:  bash switch.sh light | dark | auto | toggle | status
# Undo: bash uninstall.sh
#
# Options
#   --dark            start with the dark variant instead of light
#   --auto            turn on day/night switching right away (light by day, dark at night)
#   --reinstall       already installed? uninstall first, then install again (after a `git pull`);
#                     keeps the variant (or day/night switching) you were using
#   --files-only      copy the themes but change no settings (pick them in System Settings)
#   --keep-fonts      leave your UI fonts alone (Rajdhani/Orbitron are still installed)
#   --keep-wallpaper  leave your wallpaper alone (the Daemon wallpaper is still installed)
#   --no-kvantum      skip the Kvantum widget style (default: Kvantum is required, as the theme is drawn for it)
#   --keep-vscode     don't install or select the VS Code themes (done only if `code` is installed)
#
# Every added path and the previous value of every changed setting go to backup/<timestamp>/state.txt
# (fields separated by 0x1f; backup/current points at it); uninstall.sh puts everything back from
# there. Any failure rolls back.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_HOME=$HERE
UP="$HERE/upstream" LT="$HERE/light"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
BACKUP_ROOT="${DAEMON_BACKUP_ROOT:-$HERE/backup}"
NOVAL="__UNSET__"
APPLY=1 FONTS=1 WALL=1 KVANTUM=1 VSCODE=1 VARIANT="" AUTO="" REINSTALL=0
declare -A KEEPFONT=()
# shellcheck source=lib/variants.sh
source "$HERE/lib/variants.sh"

for a in "$@"; do
    case $a in
        --light)          VARIANT=light ;;
        --dark)           VARIANT=dark ;;
        --auto)           AUTO=1 ;;
        --reinstall)      REINSTALL=1 ;;
        --files-only)     APPLY=0 ;;
        --keep-fonts)     FONTS=0 ;;
        --keep-wallpaper) WALL=0 ;;
        --no-kvantum)     KVANTUM=0 ;;
        --keep-vscode)    VSCODE=0 ;;
        -h|--help)        sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
    esac
done

fail() { echo "     $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || fail "run this as your normal user, not with sudo (it only touches your home folder)"

if [[ -e $BACKUP_ROOT/current ]] && (( REINSTALL )); then
    prev=$(daemon_current)
    [[ -n $prev ]] || prev=$(cat "$BACKUP_ROOT/current/variant" 2>/dev/null || echo dark)   # older installs were dark only
    was_auto=""
    if [[ $(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel) == true &&
          $(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel) == "$DAEMON_LNF_LIGHT" ]]; then
        was_auto=1
        [[ -n $VARIANT ]] || AUTO=${AUTO:-1}
    fi
    VARIANT=${VARIANT:-$prev}
    # fonts are yours to tune after installing; a reinstall keeps them instead of the theme's defaults
    for gk in General/font General/menuFont General/toolBarFont General/smallestReadableFont General/fixed WM/activeFont; do
        KEEPFONT[$gk]=$(kreadconfig6 --file kdeglobals --group "${gk%/*}" --key "${gk#*/}")
    done
    echo "0/5  Reinstall: removing the installed copy first (it was on the $prev variant${was_auto:+, with day/night switching})"
    bash "$HERE/uninstall.sh" >/dev/null || fail "uninstall.sh failed; nothing was reinstalled"
fi
VARIANT=${VARIANT:-light}
daemon_variant "$VARIANT"

echo "1/5  Preflight"
for t in kreadconfig6 kwriteconfig6 plasma-apply-colorscheme plasma-apply-desktoptheme plasma-apply-lookandfeel busctl python3; do
    command -v "$t" >/dev/null || fail "$t not found (is this a Plasma 6 system?)"
done
plasmashell --version 2>/dev/null | grep -q ' 6\.' || fail "Plasma 6 is required (plasmashell --version says: $(plasmashell --version 2>&1 | head -1))"
busctl --user list --no-legend >/dev/null 2>&1 || fail "no user D-Bus session; run this from your desktop session"
[[ -d $UP/plasma-style && -d $LT/plasma-style && -d $HERE/global-themes && -d $HERE/wallpaper/Daemon-2.0 && -d $HERE/fonts ]] ||
    fail "project files missing under $HERE"
[[ ! -e $BACKUP_ROOT/current ]] || fail "already installed (state: $(readlink -f "$BACKUP_ROOT/current")); run uninstall.sh first, or install.sh --reinstall"
if (( APPLY && KVANTUM )) && ! command -v kvantummanager >/dev/null; then
    fail "Kvantum is not installed. Run:  sudo apt install qt-style-kvantum   then re-run this script (or pass --no-kvantum)"
fi
echo "     Plasma $(plasmashell --version 2>/dev/null | awk '{print $2}'), session $(printenv XDG_SESSION_TYPE || echo '?')"

echo "2/5  Back up the current appearance"
BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
n=2; base=$BACKUP; while [[ -e $BACKUP ]]; do BACKUP="$base-$n"; n=$((n+1)); done   # a --reinstall can land in the same second
STATE="$BACKUP/state.txt"
STAGE="$BACKUP/staged"   # files generated for this machine before they are put in place
install -d "$BACKUP/rc" "$BACKUP/displaced" "$STAGE"
for f in kdeglobals kwinrc plasmarc kcminputrc konsolerc ksplashrc plasma-org.kde.plasma.desktop-appletsrc Kvantum/kvantum.kvconfig; do
    [[ -f $CONF/$f ]] && cp -a "$CONF/$f" "$BACKUP/rc/$(basename "$f")"
done
: > "$STATE"
ln -sfn "$BACKUP" "$BACKUP_ROOT/current"
echo "     $BACKUP"

rec() { local IFS=$'\x1f'; printf '%s\n' "$*" >> "$STATE"; }
quiet() { local out; if ! out=$("$@" 2>&1); then printf '%s\n' "$out" >&2; return 1; fi; }  # show a tool's output only if it fails

rollback() {
    trap - ERR
    echo; echo "     Something failed; restoring your previous appearance..." >&2
    bash "$HERE/uninstall.sh" --from "$BACKUP" || true
    exit 1
}
trap rollback ERR

put() {  # put SRC DST : copy a file or folder; anything already at DST is moved aside and restored on uninstall
    local src=$1 dst=$2 keep
    if [[ -e $dst || -L $dst ]]; then
        keep="$BACKUP/displaced/$(printf '%s' "$dst" | tr / _)"
        mv "$dst" "$keep"; rec MOVED "$dst" "$keep"
    fi
    mk_parents "$(dirname "$dst")"
    rec PATH "$dst"
    cp -a "$src" "$dst"
}

mk_parents() {  # create a folder and any missing parents, recording each new one so uninstall can remove it if left empty
    local d=$1 k; local -a fresh=()
    while [[ ! -d $d ]]; do fresh+=("$d"); d=$(dirname "$d"); done
    for ((k = ${#fresh[@]} - 1; k >= 0; k--)); do rec MKDIR "${fresh[k]}"; done
    mkdir -p "$1"
}

global_theme() {  # global_theme light|dark : stage the package with this machine's decoration plugin, then put it
    local v=$1 src dst
    daemon_variant "$v"
    src="$HERE/global-themes/$V_LNF" dst="$STAGE/$V_LNF"
    cp -a "$src" "$dst"
    sed -i "s/^library=.*/library=$(daemon_aurorae_library)/" "$dst/contents/defaults"
    (( KVANTUM )) || sed -i '/^widgetStyle=/d' "$dst/contents/defaults"
    put "$dst" "$DATA/plasma/look-and-feel/$V_LNF"
}

launcher() {  # launcher light|dark : an app-menu / KRunner entry that runs switch.sh
    local v=$1 f="$STAGE/daemon-theme-$1.desktop"
    daemon_variant "$v"
    cat > "$f" <<EOF
[Desktop Entry]
Type=Application
Name=$V_LABEL
GenericName=Switch to the $v Daemon theme
Comment=Make $V_LABEL the active look and turn day/night switching off
Exec=bash "$HERE/switch.sh" --notify $v
Icon=preferences-desktop-theme-global
Terminal=false
Categories=Settings;DesktopSettings;
Keywords=theme;daemon;light;dark;appearance;
EOF
    put "$f" "$DATA/applications/daemon-theme-$v.desktop"
}

follower() {  # an autostart entry: Konsole and VS Code follow the global theme, also when day/night switching flips it
    local f="$STAGE/daemon-theme-follow.desktop"
    cat > "$f" <<EOF
[Desktop Entry]
Type=Application
Name=Daemon theme follower
Comment=Switches Konsole and VS Code between Daemon 2.0 and Daemon 2.0 Light along with the global theme
Exec=bash "$HERE/switch.sh" --follow
Icon=preferences-desktop-theme-global
Terminal=false
NoDisplay=true
X-KDE-autostart-phase=2
EOF
    put "$f" "$CONF/autostart/daemon-theme-follow.desktop"
}

echo "3/5  Copy the theme files (both variants)"
put "$UP/Daemon2.colors"                       "$DATA/color-schemes/Daemon2.colors"
put "$LT/Daemon2Light.colors"                  "$DATA/color-schemes/Daemon2Light.colors"
put "$UP/plasma-style/Daemon-2.0"              "$DATA/plasma/desktoptheme/Daemon-2.0"
put "$LT/plasma-style/Daemon-2.0-Light"        "$DATA/plasma/desktoptheme/Daemon-2.0-Light"
put "$UP/aurorae/daemon-2.0"                   "$DATA/aurorae/themes/daemon-2.0"
put "$LT/aurorae/daemon-2.0-light"             "$DATA/aurorae/themes/daemon-2.0-light"
put "$UP/icons/Daemon-Icons"                   "$DATA/icons/Daemon-Icons"
put "$LT/icons/Daemon-Icons-Light"             "$DATA/icons/Daemon-Icons-Light"
put "$UP/konsole/Daemon-2.0.colorscheme"       "$DATA/konsole/Daemon-2.0.colorscheme"
put "$LT/konsole/Daemon-2.0-Light.colorscheme" "$DATA/konsole/Daemon-2.0-Light.colorscheme"
put "$HERE/konsole/Daemon.profile"             "$DATA/konsole/Daemon.profile"
put "$HERE/konsole/Daemon-Light.profile"       "$DATA/konsole/Daemon-Light.profile"
put "$LT/kvantum/Daemon"                       "$CONF/Kvantum/Daemon"
put "$LT/kvantum/DaemonDark"                   "$CONF/Kvantum/DaemonDark"
put "$HERE/fonts"                              "$DATA/fonts/daemon-kde"
put "$HERE/wallpaper/Daemon-2.0"               "$DATA/wallpapers/Daemon-2.0"
global_theme light; global_theme dark
launcher light; launcher dark
daemon_variant "$VARIANT"
command -v fc-cache >/dev/null && fc-cache -f "$DATA/fonts/daemon-kde" >/dev/null 2>&1 || true
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
echo "     global themes 'Daemon 2.0' and 'Daemon 2.0 Light', with their color schemes, Plasma styles,"
echo "     window decorations, icons, Kvantum and Konsole themes; fonts, wallpaper, two launchers"

if (( ! APPLY )); then
    echo "4/5  Apply: skipped (--files-only)"
    echo "5/5  Done. Pick 'Daemon 2.0' or 'Daemon 2.0 Light' in System Settings > Global Theme."
    exit 0
fi

cfg() {  # cfg FILE GROUP KEY VALUE : write a setting, remembering the value it had before
    local old
    old=$(kreadconfig6 --file "$1" --group "$2" --key "$3" --default "$NOVAL")
    rec CFG "$1" "$2" "$3" "$old"
    kwriteconfig6 --notify --file "$1" --group "$2" --key "$3" "$4"
}
remember() { rec CFG "$1" "$2" "$3" "$(kreadconfig6 --file "$1" --group "$2" --key "$3" --default "$NOVAL")"; }

echo "4/5  Apply $V_LABEL"
# applying a global theme writes its values into ~/.config/kdedefaults (Plasma's defaults layer) and
# clears the matching user settings; keep a copy of that folder, and the user values, for uninstall
if [[ -d $CONF/kdedefaults ]]; then cp -a "$CONF/kdedefaults" "$BACKUP/kdedefaults"; rec KDEDEFAULTS "$CONF/kdedefaults" "$BACKUP/kdedefaults"
else rec KDEDEFAULTS "$CONF/kdedefaults" ""; fi
rec COLORS "$(kreadconfig6 --file kdeglobals --group General --key ColorScheme --default BreezeDark)"
rec ICONS "$(kreadconfig6 --file kdeglobals --group Icons --key Theme --default breeze-dark)"
rec PSTYLE "$(kreadconfig6 --file plasmarc --group Theme --key name --default breeze)"
remember kdeglobals KDE LookAndFeelPackage
remember kdeglobals KDE widgetStyle
remember kwinrc org.kde.kdecoration2 library
remember kwinrc org.kde.kdecoration2 theme
remember ksplashrc KSplash Theme
if (( KVANTUM )); then
    [[ -f $CONF/Kvantum/kvantum.kvconfig ]] || rec NEWFILE "$CONF/Kvantum/kvantum.kvconfig"
    cfg "$CONF/Kvantum/kvantum.kvconfig" General theme "$DAEMON_KVANTUM"
fi
quiet daemon_apply_global
echo "     global theme      $V_LABEL (colors $V_COLORS, icons $V_ICONS, Plasma style $V_PSTYLE,"
echo "                       window decoration $V_AURORAE$( (( KVANTUM )) && echo ", widget style $V_STYLE / Kvantum $DAEMON_KVANTUM"))"

cfg kdeglobals KDE DefaultLightLookAndFeel "$DAEMON_LNF_LIGHT"
cfg kdeglobals KDE DefaultDarkLookAndFeel  "$DAEMON_LNF_DARK"
if [[ -n $AUTO ]]; then
    cfg kdeglobals KDE AutomaticLookAndFeel true
    echo "     day/night         on: Daemon 2.0 Light by day, Daemon 2.0 at night"
else
    remember kdeglobals KDE AutomaticLookAndFeel
    echo "     day/night         pair set (light: Daemon 2.0 Light, dark: Daemon 2.0); turn on with: switch.sh auto"
fi

if (( FONTS )); then
    F() { printf '%s,%s,-1,5,%s,0,0,0,0,0,0,0,0,0,0,%s,%s' "$1" "$2" "$3" "$4" "$5"; }
    font() {  # font GROUP KEY THEME-DEFAULT : on a reinstall, the value you had wins
        local mine=${KEEPFONT[$1/$2]:-}
        cfg kdeglobals "$1" "$2" "${mine:-$3}"
    }
    UI=$(F Rajdhani 10 500 1 Medium); SMALL=$(F Rajdhani 8 500 1 Medium)
    font General font                 "$UI"
    font General menuFont             "$UI"
    font General toolBarFont          "$UI"
    font General smallestReadableFont "$SMALL"
    font General fixed                "Hack,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    font WM      activeFont           "Orbitron,8,-1,5,400,0,0,0,0,0,0,0,0,0,0,0,Regular"
    if [[ -n ${KEEPFONT[General/font]:-} ]]; then echo "     fonts             kept as you had them ($(kreadconfig6 --file kdeglobals --group General --key font | cut -d, -f1,2))"
    else echo "     fonts             Rajdhani Medium 10 / Hack 10 / Orbitron 8 (titles)"; fi
else
    echo "     fonts             unchanged (--keep-fonts)"
fi

apply_wallpaper() {  # remember each desktop's wallpaper, then point every desktop at the Daemon package
    local prev id plugin image
    prev=$(busctl --user --json=short call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s \
        "desktops().forEach(function(d){d.currentConfigGroup=['Wallpaper','org.kde.image','General'];print(d.id+'|'+d.wallpaperPlugin+'|'+d.readConfig('Image')+'\\n')})" |
        python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0],end='')") || return 1
    while IFS='|' read -r id plugin image; do
        if [[ -n $id ]]; then rec WALL "$id" "$plugin" "$image"; fi
    done <<< "$prev"
    busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s \
        "desktops().forEach(function(d){d.wallpaperPlugin='org.kde.image';d.currentConfigGroup=['Wallpaper','org.kde.image','General'];d.writeConfig('Image','file://$DATA/wallpapers/Daemon-2.0')})" >/dev/null || return 1
}

VSC_SETTINGS="$CONF/Code/User/settings.json"
vsc_set() {  # vsc_set KEY VALUE : change one VS Code setting, recording the old value
    rec VSCSETTING "$VSC_SETTINGS" "$1" "$(python3 "$HERE/vscode/theme-setting.py" --key "$1" "$VSC_SETTINGS" get)"
    python3 "$HERE/vscode/theme-setting.py" --key "$1" "$VSC_SETTINGS" set "$2"
}
if (( VSCODE )) && command -v code >/dev/null; then
    quiet code --install-extension "$HERE/vscode/daemon-2-0.vsix" --force
    rec VSCEXT undefined_publisher.daemon-2-0
    rec VSCTHEME "$VSC_SETTINGS" "$(python3 "$HERE/vscode/theme-setting.py" "$VSC_SETTINGS" get)"
    daemon_apply_vscode "$VSC_SETTINGS"
    # VS Code follows the system's light/dark preference by itself with these three
    vsc_set workbench.preferredLightColorTheme "Daemon-2.0 Light"
    vsc_set workbench.preferredDarkColorTheme  "Daemon-2.0"
    vsc_set window.autoDetectColorScheme       true
    # KDE's (Daemon) window frame instead of VS Code's own title bar, like every other app
    vsc_set window.titleBarStyle native
    echo "     VS Code           Daemon-2.0 / Daemon-2.0 Light, following the system; native title bar; restart VS Code"
elif (( VSCODE )); then
    echo "     VS Code           not installed; skipped"
fi

remember konsolerc "Desktop Entry" DefaultProfile
daemon_apply_konsole
echo "     Konsole           default profile $V_KONSOLE_NAME; follows the global theme"

if (( WALL )); then
    if busctl --user list --no-legend 2>/dev/null | awk '{print $1}' | grep -qx org.kde.plasmashell; then
        if apply_wallpaper; then echo "     wallpaper         Daemon 2.0 on $(grep -c '^WALL' "$STATE") desktop(s); light or dark follows the colors"
        else echo "     wallpaper         not applied (the Plasma shell did not answer); pick 'Daemon 2.0' in Desktop settings"; fi
    else
        echo "     wallpaper         not applied (Plasma shell is not running); pick 'Daemon 2.0' in Desktop settings"
    fi
else
    echo "     wallpaper         unchanged (--keep-wallpaper)"
fi

follower
echo "$VARIANT" > "$BACKUP/variant"
setsid nohup bash "$HERE/switch.sh" --follow >/dev/null 2>&1 < /dev/null &
echo "     follower          started; it starts with every login from ~/.config/autostart"

echo "5/5  Tell running applications"
daemon_notify
trap - ERR
cat <<EOF

Installed. $V_LABEL is active; both themes are in System Settings > Colors & Themes > Global Theme.
Log out and back in once: that is when the Orbitron window titles appear (KWin reads that font only at
startup) and when already-open applications pick up the new fonts and widget style.
Switch:  bash $HERE/switch.sh light | dark | auto | toggle   (or search "Daemon 2.0" in the launcher)
Undo:    bash $HERE/uninstall.sh
EOF
