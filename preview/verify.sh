#!/usr/bin/env bash
# Regression test for install.sh / switch.sh / uninstall.sh, run entirely inside a throwaway Plasma session
# (see nested-session.sh): its own D-Bus, home, config and virtual display. Your real desktop is never touched.
#   bash preview/verify.sh            run the checks, refresh preview/gallery/*.png, print PASS/FAIL
#   bash preview/verify.sh --keep     keep the session folder afterwards (default: deleted)
# Takes about 5 minutes. Kvantum is fetched with `apt-get download` if missing (no root, session-only).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
INSTALL="$ROOT/install.sh" UNINSTALL="$ROOT/uninstall.sh" SWITCH="$ROOT/switch.sh"
GALLERY="$HERE/gallery"
KEEP=0; [[ ${1:-} == --keep ]] && KEEP=1
# shellcheck source=nested-session.sh
source "$HERE/nested-session.sh"

PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
expect() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
val() { kreadconfig6 --file "$1" --group "$2" --key "$3" --default '(unset)'; }
wallpaper() {
    busctl --user --json=short call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s \
        "desktops().forEach(function(d){d.currentConfigGroup=['Wallpaper','org.kde.image','General'];print(d.id+' '+d.wallpaperPlugin+' '+d.readConfig('Image')+'\\n')})" |
        python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0].strip())'
}
fingerprint() {  # everything install.sh may touch, as text, so two states can be compared exactly
    local kv v
    for kv in "kdeglobals General ColorScheme" "kdeglobals Icons Theme" "kdeglobals KDE widgetStyle" "kdeglobals General font" \
              "kdeglobals General menuFont" "kdeglobals General toolBarFont" "kdeglobals General smallestReadableFont" \
              "kdeglobals General fixed" "kdeglobals WM activeFont" "plasmarc Theme name" \
              "kwinrc org.kde.kdecoration2 library" "kwinrc org.kde.kdecoration2 theme" \
              "kdeglobals Colors:Window BackgroundNormal" "kdeglobals Colors:View BackgroundNormal" "kdeglobals Colors:Selection BackgroundNormal" \
              "kdeglobals KDE LookAndFeelPackage" "kdeglobals KDE DefaultLightLookAndFeel" "kdeglobals KDE DefaultDarkLookAndFeel" \
              "kdeglobals KDE AutomaticLookAndFeel" "ksplashrc KSplash Theme"; do
        # KWin 6.6 renames the Aurorae library at startup; applying a global theme writes AutomaticLookAndFeel=false (= unset)
        set -- $kv; v=$(val "$1" "$2" "$3" | sed 's/^org\.kde\.kwin\.aurorae\.v2$/org.kde.kwin.aurorae/')
        [[ $3 == AutomaticLookAndFeel && $v == false ]] && v='(unset)'
        echo "$1|$2|$3=$v"
    done
    echo "konsolerc|Desktop Entry|DefaultProfile=$(val konsolerc 'Desktop Entry' DefaultProfile)"
    echo "kvantum.kvconfig=$( [[ -e $XDG_CONFIG_HOME/Kvantum/kvantum.kvconfig ]] && tr '\n' ' ' < "$XDG_CONFIG_HOME/Kvantum/kvantum.kvconfig" || echo none)"
    echo "wallpaper=$(wallpaper)"
    ( cd "$XDG_DATA_HOME" && find color-schemes plasma/desktoptheme plasma/look-and-feel aurorae icons konsole fonts wallpapers applications -maxdepth 1 2>/dev/null | sort )
    ( cd "$XDG_CONFIG_HOME" && find Kvantum autostart -maxdepth 1 2>/dev/null | sort )
    ( cd "$XDG_CONFIG_HOME" && for f in kdedefaults/*; do [[ -f $f ]] && { echo "-- $f"; cat "$f"; echo; }; done 2>/dev/null )   # global themes write here
    echo "install-state=$([[ -e $DAEMON_BACKUP_ROOT/current ]] && echo present || echo none)"
}
same_as_baseline() { [[ "$(fingerprint)" == "$BASELINE" ]]; }
show_diff() { diff <(echo "$BASELINE") <(fingerprint) | head -12 | sed 's/^/        /'; }
follower_up() { nest_app bash "$SWITCH" --follow; sleep 2; }   # what the autostart entry does at login
follower_alive() { local p; p=$(cat "$DAEMON_BACKUP_ROOT/current/follow.pid" 2>/dev/null) && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--follow'; }
wait_for() { local i; for ((i = 0; i < ${2:-20}; i++)); do eval "$1" && return 0; sleep 0.5; done; return 1; }
konsole_profiles() {  # the profile name of every open Konsole tab
    local svc path
    for svc in $(busctl --user list --no-legend | awk '$1 ~ /^org\.kde\.konsole/ {print $1}'); do
        for path in $(busctl --user tree --list "$svc" 2>/dev/null | grep -E '^/Sessions/[0-9]+$'); do
            busctl --user call "$svc" "$path" org.kde.konsole.Session profile 2>/dev/null | sed 's/^s "\(.*\)"$/\1/'
        done
    done
}
apps_up() { nest_app dolphin "$HOME"; sleep 3; nest_app systemsettings kcm_colors; sleep 3; nest_app kcalc; sleep 3; nest_app konsole --separate --workdir "$HOME"; sleep 8; nest_arrange; sleep 3; }

REAL_CFG=("$HOME/.config/kdeglobals" "$HOME/.config/kwinrc" "$HOME/.config/plasmarc" "$HOME/.config/kcminputrc" "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc")
real_cfg_sums() { sha256sum "${REAL_CFG[@]}" 2>/dev/null; ls -d "$HOME"/.local/share/{color-schemes,plasma/desktoptheme,icons,aurorae/themes}/*aemon* "$HOME/.config/Kvantum" 2>/dev/null; }
crash_count() { echo "$(coredumpctl list --no-pager 2>/dev/null | grep -c '^') $(ls /var/crash 2>/dev/null | wc -l)"; }
REAL_BEFORE="$(real_cfg_sums)"; CRASH_BEFORE="$(crash_count)"

echo "== Starting the throwaway Plasma session"
nest_start || { echo "could not start the test session" >&2; nest_stop; exit 2; }
# safety: never run installs against the real session
if [[ $HOME != "$NEST/home" || $DBUS_SESSION_BUS_ADDRESS == *"/run/user/$(id -u)/bus"* ]]; then
    echo "refusing to run: the environment does not point at the throwaway session" >&2; nest_stop; exit 2
fi
mkdir -p "$GALLERY"
echo "   Plasma $(plasmashell --version 2>/dev/null | awk '{print $2}'), Kvantum: $(command -v kvantummanager || echo 'not available')"

echo "== 1. Screenshots: before"
apps_up; nest_shot 1-before && cp "$NEST/shots/1-before.png" "$GALLERY/" && ok "captured the stock look"
nest_kill_clients; sleep 2
BASELINE="$(fingerprint)"   # taken after the apps ran once, so folders they create themselves are part of "before"

echo "== 2. Preflight: no Kvantum -> clear message, nothing changed"
if command -v kvantummanager >/dev/null && [[ $(command -v kvantummanager) != "$NEST"/* ]]; then
    echo "  SKIP  Kvantum is installed system-wide"
else
    out=$(PATH="${PATH//$NEST\/kvroot\/usr\/bin:/}" bash "$INSTALL" 2>&1); rc=$?
    [[ $rc -ne 0 && $out == *"sudo apt install qt-style-kvantum"* ]] && ok "stops and tells you to install Kvantum" || bad "kvantum preflight (rc=$rc)"
    same_as_baseline && ok "...and changed nothing" || { bad "...and changed nothing"; show_diff; }
fi

echo "== 3. --files-only: files yes, settings no, clean uninstall"
bash "$INSTALL" --files-only >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "install --files-only exits 0" || bad "install --files-only (rc=$rc)"
[[ -f $XDG_DATA_HOME/color-schemes/Daemon2.colors && -d $XDG_DATA_HOME/icons/Daemon-Icons && -d $XDG_CONFIG_HOME/Kvantum/DaemonDark ]] && ok "dark theme files are in place" || bad "dark theme files are in place"
[[ -f $XDG_DATA_HOME/color-schemes/Daemon2Light.colors && -d $XDG_DATA_HOME/icons/Daemon-Icons-Light && -d $XDG_CONFIG_HOME/Kvantum/Daemon && -d $XDG_DATA_HOME/plasma/desktoptheme/Daemon-2.0-Light && -d $XDG_DATA_HOME/aurorae/themes/daemon-2.0-light ]] && ok "light theme files are in place" || bad "light theme files are in place"
lnf=$(plasma-apply-lookandfeel --list 2>/dev/null)
[[ $lnf == *org.daemonkde.light.desktop* && $lnf == *org.daemonkde.dark.desktop* ]] && ok "both global themes are listed (System Settings > Global Theme)" || bad "global themes listed"
[[ $(val kdeglobals General ColorScheme) == BreezeDark && $(val plasmarc Theme name) == kubuntu-dark ]] && ok "settings untouched" || bad "settings untouched"
bash "$SWITCH" light >/dev/null 2>&1 && bad "switch.sh after --files-only should refuse" || ok "switch.sh refuses on a --files-only install"
bash "$UNINSTALL" >/dev/null 2>&1
same_as_baseline && ok "uninstall returns to the exact baseline" || { bad "uninstall returns to the exact baseline"; show_diff; }

is_variant() {  # is_variant dark|light : every per-variant setting points at that variant
    local c i p a st pr g
    if [[ $1 == light ]]; then g=org.daemonkde.light.desktop c=Daemon2Light i=Daemon-Icons-Light p=Daemon-2.0-Light a=__aurorae__svg__daemon-2.0-light st=kvantum pr=Daemon-Light.profile
    else g=org.daemonkde.dark.desktop c=Daemon2 i=Daemon-Icons p=Daemon-2.0 a=__aurorae__svg__daemon-2.0 st=kvantum-dark pr=Daemon.profile; fi
    [[ $(val kdeglobals KDE LookAndFeelPackage) == "$g" && $(val kdeglobals General ColorScheme) == "$c" && $(val kdeglobals Icons Theme) == "$i" &&
       $(val plasmarc Theme name) == "$p" && $(val kwinrc org.kde.kdecoration2 theme) == "$a" && $(val kdeglobals KDE widgetStyle) == "$st" &&
       $(val "$XDG_CONFIG_HOME/Kvantum/kvantum.kvconfig" General theme) == Daemon &&
       $(val konsolerc 'Desktop Entry' DefaultProfile) == "$pr" && $(cat "$DAEMON_BACKUP_ROOT/current/variant" 2>/dev/null) == "$1" ]]
}

echo "== 4. Full install (light is the default)"
out=$(bash "$INSTALL" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "install exits 0" || { bad "install exits 0 (rc=$rc)"; echo "$out" | tail -5 | sed 's/^/        /'; }
[[ $(val kdeglobals General ColorScheme) == Daemon2Light ]]                    && ok "colors: Daemon2Light"       || bad "colors"
[[ $(val kdeglobals Icons Theme) == Daemon-Icons-Light ]]                      && ok "icons: Daemon-Icons-Light"  || bad "icons"
[[ $(val plasmarc Theme name) == Daemon-2.0-Light ]]                           && ok "Plasma style: Daemon-2.0-Light" || bad "Plasma style"
[[ $(val kwinrc org.kde.kdecoration2 theme) == __aurorae__svg__daemon-2.0-light ]] && ok "window decoration: Aurorae light" || bad "window decoration"
[[ $(val kdeglobals KDE widgetStyle) == kvantum ]]                             && ok "widget style: Kvantum"      || bad "widget style"
is_variant light                                                               && ok "every part is the light variant (global theme, Kvantum, Konsole, record)" || bad "light variant everywhere"
[[ $(val kdeglobals KDE DefaultLightLookAndFeel) == org.daemonkde.light.desktop && $(val kdeglobals KDE DefaultDarkLookAndFeel) == org.daemonkde.dark.desktop ]] && ok "day/night pair: Daemon 2.0 Light by day, Daemon 2.0 at night" || bad "day/night pair"
[[ $(val kdeglobals KDE AutomaticLookAndFeel) != true ]]                       && ok "day/night switching left off by default" || bad "day/night left off"
wait_for follower_alive 10 && [[ -f $XDG_CONFIG_HOME/autostart/daemon-theme-follow.desktop ]] && ok "follower running, and in autostart" || bad "follower running"
[[ -f $XDG_DATA_HOME/applications/daemon-theme-light.desktop && -f $XDG_DATA_HOME/applications/daemon-theme-dark.desktop ]] && ok "launcher entries for both variants" || bad "launcher entries"
[[ $(val kdeglobals General font) == Rajdhani,10,* ]]                          && ok "UI font: Rajdhani"          || bad "UI font"
[[ $(val kdeglobals WM activeFont) == Orbitron,8,* ]]                          && ok "title font: Orbitron"       || bad "title font"
[[ $(wallpaper) == *"wallpapers/Daemon-2.0"* ]]                                && ok "wallpaper: Daemon 2.0"      || bad "wallpaper"
fc-list | grep -qi rajdhani && fc-list | grep -qi orbitron                     && ok "fonts visible to fontconfig" || bad "fonts visible to fontconfig"
[[ -f $XDG_DATA_HOME/konsole/Daemon-Light.profile && -f $XDG_DATA_HOME/konsole/Daemon-2.0-Light.colorscheme ]] && ok "Konsole: light profile and scheme installed" || bad "Konsole light profile"
if command -v code >/dev/null; then
    VSJ=$XDG_CONFIG_HOME/Code/User/settings.json
    grep -q '"window.autoDetectColorScheme": true' "$VSJ" && grep -q '"workbench.preferredLightColorTheme": "Daemon-2.0 Light"' "$VSJ" &&
        ok "VS Code follows the system (autoDetectColorScheme is a real boolean)" || bad "VS Code settings: $(grep -E 'autoDetect|preferred' "$VSJ" | tr -s ' ')"
fi
before2="$(fingerprint)"
bash "$INSTALL" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$(fingerprint)" == "$before2" ]] && ok "a second install is refused and changes nothing" || bad "second install refused (rc=$rc)"

echo "== 5. Screenshots: after install, then after 'logging in again'"
apps_up; nest_shot 2-light-after-install && cp "$NEST/shots/2-light-after-install.png" "$GALLERY/" && ok "captured (session as it is right after install)"
nest_restart; follower_up; apps_up; nest_shot 3-light-after-relogin && cp "$NEST/shots/3-light-after-relogin.png" "$GALLERY/" && ok "captured (after restarting KWin: Orbitron titles)"

echo "== 5a. Picking a global theme elsewhere (System Settings, day/night switching): Konsole follows"
[[ $(konsole_profiles | sort -u) == "Daemon Light" ]] && ok "open Konsole tab uses the Daemon Light profile" || bad "Konsole tab profile: $(konsole_profiles | tr '\n' ' ')"
plasma-apply-lookandfeel -a org.daemonkde.dark.desktop >/dev/null 2>&1
wait_for 'is_variant dark' 30 && ok "follower: Konsole default profile and record went dark by themselves" || bad "follower did not follow the dark global theme"
wait_for '[[ $(konsole_profiles | sort -u) == Daemon ]]' 20 && ok "...and the open Konsole tab switched live" || bad "live Konsole tab: $(konsole_profiles | tr '\n' ' ')"
plasma-apply-lookandfeel -a org.daemonkde.light.desktop >/dev/null 2>&1
wait_for 'is_variant light' 30 && ok "...and back to light" || bad "follower back to light"
bash "$SWITCH" auto >/dev/null 2>&1 && [[ $(val kdeglobals KDE AutomaticLookAndFeel) == true ]] && ok "switch.sh auto turns day/night switching on" || bad "switch.sh auto"
[[ $(bash "$SWITCH" status 2>&1) == *"day/night switching is on"* ]] && ok "switch.sh status reports it" || bad "status after auto"
bash "$SWITCH" light >/dev/null 2>&1 && [[ $(val kdeglobals KDE AutomaticLookAndFeel) == false ]] && is_variant light && ok "switch.sh light turns it off again" || bad "switch.sh light after auto"
kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel --delete   # as before the test (unset)
nest_kill_clients; sleep 2
nest_app systemsettings kcm_lookandfeel; sleep 10
nest_shot 6-global-themes && cp "$NEST/shots/6-global-themes.png" "$GALLERY/" && ok "captured System Settings > Global Theme"
nest_kill_clients; sleep 2

echo "== 5b. switch.sh: dark, toggle back, and a reinstall keeps the variant"
installed="$(fingerprint)"
bash "$SWITCH" dark >/dev/null 2>&1 && is_variant dark   && ok "switch.sh dark: every part is the dark variant" || bad "switch.sh dark"
[[ $(val kdeglobals General font) == Rajdhani,10,* && $(wallpaper) == *"wallpapers/Daemon-2.0"* ]] && ok "...fonts and wallpaper package untouched" || bad "switch left fonts/wallpaper alone"
nest_restart; follower_up; apps_up; nest_shot 4-dark-after-switch && cp "$NEST/shots/4-dark-after-switch.png" "$GALLERY/" && ok "captured the dark variant"
nest_kill_clients; sleep 2
bash "$SWITCH" toggle >/dev/null 2>&1 && is_variant light && ok "switch.sh toggle: back to light"  || bad "switch.sh toggle"
[[ "$(fingerprint)" == "$installed" ]] && ok "...and exactly as right after install"   || { bad "toggle back = as installed"; diff <(echo "$installed") <(fingerprint) | head -8 | sed 's/^/        /'; }
[[ $(bash "$SWITCH" status 2>&1) == "Daemon 2.0 Light is active; day/night switching is off" ]] && ok "switch.sh status" || bad "switch.sh status: $(bash "$SWITCH" status 2>&1)"
bash "$SWITCH" dark >/dev/null 2>&1
themefont=$(val kdeglobals General font); myfont="Rajdhani SemiBold,12,-1,5,600,0,0,0,0,0,0,0,0,0,0,1,Regular"
kwriteconfig6 --file kdeglobals --group General --key font "$myfont"   # a font you tuned after installing
out=$(bash "$INSTALL" --reinstall 2>&1); rc=$?
[[ $(val kdeglobals General font) == "$myfont" ]] && ok "--reinstall keeps the fonts you changed" || bad "reinstall font: $(val kdeglobals General font)"
[[ $rc -eq 0 ]] && is_variant dark && ok "install.sh --reinstall exits 0 and keeps the dark variant" || { bad "reinstall (rc=$rc)"; echo "$out" | tail -5 | sed 's/^/        /'; }
bash "$INSTALL" --reinstall --light >/dev/null 2>&1 && is_variant light && ok "install.sh --reinstall --light switches to light" || bad "reinstall --light"
kwriteconfig6 --file kdeglobals --group General --key font "$themefont"
[[ "$(fingerprint)" == "$installed" ]] && ok "...two reinstalls later, exactly as the first install" || { bad "reinstall = as installed"; diff <(echo "$installed") <(fingerprint) | head -8 | sed 's/^/        /'; }

echo "== 6. Uninstall"
bash "$UNINSTALL" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "uninstall exits 0" || bad "uninstall exits 0 (rc=$rc)"
same_as_baseline && ok "everything is back to the exact baseline (settings, colors, wallpaper, files)" || { bad "back to the exact baseline"; show_diff; }
bash "$UNINSTALL" >/dev/null 2>&1 && bad "uninstall with nothing installed should refuse" || ok "uninstall with nothing installed refuses"
nest_restart; apps_up; nest_shot 5-after-uninstall && cp "$NEST/shots/5-after-uninstall.png" "$GALLERY/" && ok "captured the restored look"
nest_kill_clients; sleep 2

echo "== 7. A failure half-way rolls everything back"
STUB="$NEST/stub"; mkdir -p "$STUB"; REAL_LNF=$(command -v plasma-apply-lookandfeel)
# applies the global theme for real, then fails: rollback has to undo a half-applied theme
printf '#!/bin/sh\n"%s" "$@" >/dev/null 2>&1\necho "simulated failure" >&2\nexit 1\n' "$REAL_LNF" > "$STUB/plasma-apply-lookandfeel"; chmod +x "$STUB/plasma-apply-lookandfeel"
PATH="$STUB:$PATH" bash "$INSTALL" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "install reports the failure" || bad "install reports the failure"
same_as_baseline && ok "...and rollback restored the baseline (the global theme had been applied)" || { bad "rollback restored the baseline"; show_diff; }

echo "== 8. Files that were already there come back after uninstall"
mkdir -p "$XDG_DATA_HOME/color-schemes" "$XDG_DATA_HOME/icons/Daemon-Icons"
printf 'my own scheme\n' > "$XDG_DATA_HOME/color-schemes/Daemon2.colors"; touch "$XDG_DATA_HOME/icons/Daemon-Icons/my-marker"
bash "$INSTALL" --files-only >/dev/null 2>&1
[[ $(cat "$XDG_DATA_HOME/color-schemes/Daemon2.colors") != "my own scheme" ]] && ok "install replaced them with the theme's" || bad "install replaced them"
bash "$UNINSTALL" >/dev/null 2>&1
[[ $(cat "$XDG_DATA_HOME/color-schemes/Daemon2.colors" 2>/dev/null) == "my own scheme" && -e $XDG_DATA_HOME/icons/Daemon-Icons/my-marker ]] && ok "uninstall put your own files back untouched" || bad "your files restored"
rm -rf "$XDG_DATA_HOME/color-schemes/Daemon2.colors" "$XDG_DATA_HOME/icons/Daemon-Icons"
rmdir "$XDG_DATA_HOME/color-schemes" "$XDG_DATA_HOME/icons" 2>/dev/null   # the test made these, not install.sh
same_as_baseline && ok "...and nothing else is left behind" || { bad "nothing left behind"; show_diff; }

python3 - "$NEST/shots/3-light-after-relogin.png" "$GALLERY/zoom-fonts.png" <<'PY' 2>/dev/null
import sys
from PIL import Image
im = Image.open(sys.argv[1])
crops = [(30, 40, 470, 68), (560, 120, 1000, 146), (30, 620, 470, 646), (38, 130, 378, 230)]
tiles = [im.crop(c).resize(((c[2]-c[0])*3, (c[3]-c[1])*3), Image.LANCZOS) for c in crops]
out = Image.new("RGB", (max(t.width for t in tiles), sum(t.height for t in tiles) + 10*len(tiles)), (0, 0, 0)); y = 0
for t in tiles: out.paste(t, (0, y)); y += t.height + 10
out.save(sys.argv[2])
PY

nest_stop
echo "== 9. Nothing escaped the test session"
[[ -z $(nest_kwin_pids) ]] && ok "no test compositor left running" || bad "test compositor left running: $(nest_kwin_pids | tr '\n' ' ')"
sleep 2
[[ $(crash_count) == "$CRASH_BEFORE" ]] && ok "no crash reports created (core dumps, /var/crash)" || bad "crash reports: before $CRASH_BEFORE, after $(crash_count)"
REAL_HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
[[ "$(HOME=$REAL_HOME real_cfg_sums)" == "$REAL_BEFORE" ]] && ok "your real config files are byte-identical" || bad "your real config changed"
(( KEEP )) || rm -rf "$NEST"
echo
echo "Result: $PASS passed, $FAIL failed.  Screenshots: $GALLERY"
(( FAIL == 0 ))
