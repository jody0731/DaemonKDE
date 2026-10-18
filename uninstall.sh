#!/usr/bin/env bash
# Remove the Daemon 2.0 KDE theme (both variants) and put back the appearance it replaced, using the
# state that install.sh recorded. Also used by install.sh to roll itself back after a failure.
#   bash uninstall.sh [--from backup/<timestamp>]
# Settings are restored one by one (not by copying old config files back), so anything else you
# changed in the meantime is left alone. Fonts installed by this theme are removed; the backup
# folder stays as a record.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
BACKUP_ROOT="${DAEMON_BACKUP_ROOT:-$HERE/backup}"
NOVAL="__UNSET__"
FROM="$BACKUP_ROOT/current"
while (( $# )); do
    case $1 in
        --from) FROM="${2:?--from needs a folder}"; shift 2 ;;
        -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

[[ $EUID -ne 0 ]] || { echo "run this as your normal user, not with sudo" >&2; exit 1; }
FROM="$(readlink -f "$FROM" 2>/dev/null || echo "$FROM")"
STATE="$FROM/state.txt"
[[ -f $STATE ]] || { echo "Nothing to undo: no install state at $FROM" >&2; exit 1; }

warn() { echo "     (could not $*)" >&2; }
n_cfg=0 n_path=0

# the watcher that keeps Konsole and VS Code in step with the global theme (switch.sh --follow)
pid=$(cat "$FROM/follow.pid" 2>/dev/null || true)
if [[ -n $pid ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- 'switch.sh --follow'; then
    kill "$pid" 2>/dev/null || true
fi

echo "1/3  Restore settings"
# newest change first, so a setting written twice ends at its original value
while IFS=$'\x1f' read -r kind a b c d; do
    case $kind in
        WALL)   # a=desktop id  b=plugin  c=image
            [[ -n $b ]] || continue
            if busctl --user list --no-legend 2>/dev/null | awk '{print $1}' | grep -qx org.kde.plasmashell; then
                busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s \
                    "desktops().forEach(function(d){if(d.id==$a){d.wallpaperPlugin='$b'; d.currentConfigGroup=['Wallpaper','org.kde.image','General']; d.writeConfig('Image','$c')}})" >/dev/null 2>&1 || warn "restore wallpaper of desktop $a"
            else warn "restore wallpaper of desktop $a (Plasma shell is not running)"; fi ;;
        CFG)    # a=file b=group c=key d=old value
            if [[ $d == "$NOVAL" ]]; then kwriteconfig6 --file "$a" --group "$b" --key "$c" --delete 2>/dev/null || warn "reset $b/$c"
            else kwriteconfig6 --file "$a" --group "$b" --key "$c" "$d" 2>/dev/null || warn "restore $b/$c"; fi
            n_cfg=$((n_cfg+1)) ;;
        PSTYLE) plasma-apply-desktoptheme "$a" >/dev/null 2>&1 || warn "restore Plasma style $a" ;;
        ICONS)
            CHANGEICONS=$(ls /usr/lib/*/libexec/plasma-changeicons /usr/libexec/plasma-changeicons 2>/dev/null | head -1)
            if [[ -n $CHANGEICONS ]]; then "$CHANGEICONS" "$a" >/dev/null 2>&1 || warn "restore icons $a"
            else kwriteconfig6 --file kdeglobals --group Icons --key Theme "$a"; fi ;;
        COLORS) plasma-apply-colorscheme "$a" >/dev/null 2>&1 || warn "restore color scheme $a" ;;
        KDEDEFAULTS) # a=~/.config/kdedefaults b=saved copy, or empty if there was none (global themes write here)
            rm -rf -- "$a"
            if [[ -n $b && -d $b ]]; then cp -a -- "$b" "$a" || warn "restore $a"; fi ;;
        VSCTHEME) # a=settings.json b=old theme
            if [[ $b == "$NOVAL" ]]; then python3 "$HERE/vscode/theme-setting.py" "$a" unset || warn "reset the VS Code theme"
            else python3 "$HERE/vscode/theme-setting.py" "$a" set "$b" || warn "restore the VS Code theme"; fi ;;
        VSCSETTING) # a=settings.json b=key c=old value
            if [[ $c == "$NOVAL" ]]; then python3 "$HERE/vscode/theme-setting.py" --key "$b" "$a" unset || warn "reset VS Code $b"
            else python3 "$HERE/vscode/theme-setting.py" --key "$b" "$a" set "$c" || warn "restore VS Code $b"; fi ;;
        VSCEXT)
            if command -v code >/dev/null; then code --uninstall-extension "$a" >/dev/null 2>&1 || warn "uninstall VS Code extension $a"
            else warn "uninstall VS Code extension $a (code is not installed)"; fi ;;
    esac
done < <(tac "$STATE")
echo "     $n_cfg settings, plus colors, icons, Plasma style and wallpaper where they were changed"

echo "2/3  Remove the theme files"
while IFS=$'\x1f' read -r kind a b; do
    case $kind in
        PATH) [[ -n $a && ( -e $a || -L $a ) ]] && { rm -rf -- "$a"; n_path=$((n_path+1)); } ;;
    esac
done < <(tac "$STATE")
# anything that was already at a destination goes back
while IFS=$'\x1f' read -r kind a b; do
    if [[ $kind == MOVED && -e $b ]]; then mkdir -p "$(dirname "$a")"; mv -- "$b" "$a"; fi
done < <(tac "$STATE")
# a Kvantum config that install.sh created from nothing goes away if it is empty again
while IFS=$'\x1f' read -r kind a; do
    if [[ $kind == NEWFILE && -f $a && ! -s $a ]]; then rm -f -- "$a"; fi
done < "$STATE"
# folders install.sh had to create for the theme, children first, only if nothing else lives in them
while IFS=$'\x1f' read -r kind a; do
    if [[ $kind == MKDIR ]]; then rmdir -- "$a" 2>/dev/null || true; fi
done < <(tac "$STATE")
echo "     $n_path items removed"

echo "3/3  Tell running applications"
command -v fc-cache >/dev/null && fc-cache -f >/dev/null 2>&1
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 --noincremental >/dev/null 2>&1
busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure >/dev/null 2>&1
for kind in 1 2; do
    dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.notifyChange int32:$kind int32:0 2>/dev/null
done
[[ $(readlink -f "$BACKUP_ROOT/current" 2>/dev/null) == "$FROM" ]] && rm -f "$BACKUP_ROOT/current"
touch "$FROM/UNINSTALLED"
echo
echo "Done. Your previous appearance is back. Log out and in once so open applications drop the theme's"
echo "fonts and widget style. The record of this install stays in: $FROM"
