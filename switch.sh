#!/usr/bin/env bash
# Switch an installed Daemon theme between Daemon 2.0 (dark) and Daemon 2.0 Light.
#   bash switch.sh light | dark | toggle   apply one global theme, and turn day/night switching off
#   bash switch.sh auto                    day/night switching on: Light by day, dark at night
#   bash switch.sh status                  which one is active, and whether day/night switching is on
#   --notify   also show a desktop notification (used by the "Daemon 2.0" app-launcher entries)
#
# Manual switching (light/dark/toggle) is the default; install.sh turns day/night on only with --auto.
# The same can be done in System Settings > Colors & Themes > Global Theme. switch.sh moves Konsole
# and VS Code along; for switches made elsewhere, they follow only with the follower (`switch.sh
# --follow`, install.sh --follower; `--sync` is its one-shot step). Already-open applications switch colors at once; their Kvantum
# widgets switch when they are restarted (or after logging out and in).
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_HOME=$HERE
BACKUP_ROOT="${DAEMON_BACKUP_ROOT:-$HERE/backup}"
# shellcheck source=lib/variants.sh
source "$HERE/lib/variants.sh"

WANT="" NOTIFY=0
for a in "$@"; do
    case $a in
        light|dark|toggle|auto|status|--follow|--sync) WANT=$a ;;
        --notify) NOTIFY=1 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $a (see --help)" >&2; exit 2 ;;
    esac
done
[[ -n $WANT ]] || { sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

notify() {  # notify TEXT : a desktop notification when --notify was given, the terminal otherwise
    echo "$1"
    (( NOTIFY )) || return 0
    busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications \
        Notify susssasa{sv}i "Daemon theme" 0 preferences-desktop-theme-global "Daemon theme" "$1" 0 0 5000 >/dev/null 2>&1 || true
}
fail() { notify "$1"; exit 1; }

[[ $EUID -ne 0 ]] || fail "run this as your normal user, not with sudo"
CUR="$BACKUP_ROOT/current"
STATE="$CUR/state.txt"
[[ -f $STATE ]] || fail "The Daemon theme is not installed (no $STATE). Run install.sh first."
US=$'\x1f'
has() { grep -qF -- "$1" "$STATE"; }  # has TEXT : the install record mentions it

sync_apps() {  # Konsole and VS Code to the active global theme's variant (only the parts install.sh set up)
    local v vsc
    v=$(daemon_current)
    [[ -n $v ]] || return 0                      # another global theme is active: leave the apps alone
    [[ $v == "$(cat "$CUR/variant" 2>/dev/null)" && ${1:-} != force ]] && return 0
    daemon_variant "$v"
    if has "konsolerc${US}Desktop Entry${US}DefaultProfile"; then daemon_apply_konsole; fi
    vsc=$(grep "^VSCTHEME$US" "$STATE" | head -1 | cut -d"$US" -f2) || true
    if [[ -n $vsc ]]; then daemon_apply_vscode "$vsc"; fi
    echo "$v" > "$CUR/variant"
}

case $WANT in
    --sync) sync_apps force; exit 0 ;;
    --follow)
        # one watcher per install; it ends with the session (dbus-monitor exits when the bus goes away)
        old=$(cat "$CUR/follow.pid" 2>/dev/null || true)
        if [[ -n $old && $old != $$ ]] && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q -- 'switch.sh --follow'; then exit 0; fi
        echo $$ > "$CUR/follow.pid"
        sync_apps force || true
        exec {mon}< <(exec dbus-monitor --session \
            "type='signal',interface='org.kde.kconfig.notify',path='/kdeglobals'" \
            "type='signal',interface='org.kde.KGlobalSettings',member='notifyChange'" 2>/dev/null)
        mpid=$!
        trap 'kill $mpid 2>/dev/null; exit 0' TERM INT HUP
        while read -r -u "$mon" line; do
            [[ $line == signal* ]] || continue
            while read -r -t 1 -u "$mon" _; do :; done   # let a burst of changes settle
            sync_apps || true
        done
        exit 0 ;;
esac

grep -q "^COLORS$US" "$STATE" || fail "This install was made with --files-only, so it manages no settings. Pick the theme in System Settings > Global Theme."
[[ -d ${XDG_DATA_HOME:-$HOME/.local/share}/plasma/look-and-feel/$DAEMON_LNF_LIGHT ]] ||
    fail "This install predates the Daemon 2.0 global themes. Update with: bash $HERE/install.sh --reinstall"

AUTO_NOW=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)
if [[ $WANT == status ]]; then
    now=$(daemon_current)
    if [[ -n $now ]]; then daemon_variant "$now"; label=$V_LABEL; else label="another global theme ($(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage))"; fi
    echo "$label is active; day/night switching is $([[ $AUTO_NOW == true ]] && echo on || echo off)"
    exit 0
fi

if [[ $WANT == auto ]]; then
    kwriteconfig6 --notify --file kdeglobals --group KDE --key DefaultLightLookAndFeel "$DAEMON_LNF_LIGHT"
    kwriteconfig6 --notify --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$DAEMON_LNF_DARK"
    kwriteconfig6 --notify --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    notify "Day/night switching is on: Daemon 2.0 Light by day, Daemon 2.0 at night (times: System Settings > Night Light)."
    exit 0
fi

[[ $WANT == toggle ]] && { [[ $(daemon_current) == light ]] && WANT=dark || WANT=light; }
daemon_variant "$WANT"
[[ $AUTO_NOW == true ]] && kwriteconfig6 --notify --file kdeglobals --group KDE --key AutomaticLookAndFeel false
daemon_apply_global >/dev/null 2>&1 || fail "plasma-apply-lookandfeel could not apply $V_LABEL"
# Electron apps (Claude Desktop) restyle GTK on the portal's light/dark signal, which comes ~150 ms before KDE
# rewrites ~/.config/gtk-3.0/colors.css, so they read the previous variant's colours and end up on the opposite
# one (2026-10-23). A second apply, once the file is written, sends the signal again and puts them right.
sleep 1
daemon_apply_global >/dev/null 2>&1 || true
sync_apps force
daemon_notify
notify "$V_LABEL is now active$([[ $AUTO_NOW == true ]] && echo '; day/night switching is off (switch.sh auto turns it back on)'). Restart open applications for their widgets to follow."
