# Shared by install.sh and switch.sh (sourced, not run): what the dark and the light variant are made
# of, and how to make one of them the active look. Recording old values is install.sh's job; these
# functions only write.
#
# Each variant is a global theme (look-and-feel package, see global-themes/), so it shows up in
# System Settings > Global Theme and works with Plasma's day/night switching. Applying the package
# sets colors, icons, Plasma style, window decoration and widget style. Konsole and VS Code are not
# part of a global theme; daemon_sync_apps (run by switch.sh, and by its --follow watcher whenever the
# global theme changes) brings them along.

DAEMON_LNF_LIGHT=org.daemonkde.light.desktop
DAEMON_LNF_DARK=org.daemonkde.dark.desktop
DAEMON_KVANTUM=Daemon   # widget style "kvantum" draws it; "kvantum-dark" draws its twin DaemonDark

daemon_variant() {  # daemon_variant dark|light : sets V_* to that variant's names
    case $1 in
        dark)  V_LABEL="Daemon 2.0"       V_LNF=$DAEMON_LNF_DARK  V_COLORS=Daemon2      V_ICONS=Daemon-Icons
               V_PSTYLE=Daemon-2.0        V_AURORAE=__aurorae__svg__daemon-2.0       V_STYLE=kvantum-dark
               V_KONSOLE=Daemon.profile   V_KONSOLE_NAME="Daemon"       V_VSCODE="Daemon-2.0" ;;
        light) V_LABEL="Daemon 2.0 Light" V_LNF=$DAEMON_LNF_LIGHT V_COLORS=Daemon2Light V_ICONS=Daemon-Icons-Light
               V_PSTYLE=Daemon-2.0-Light  V_AURORAE=__aurorae__svg__daemon-2.0-light V_STYLE=kvantum
               V_KONSOLE=Daemon-Light.profile V_KONSOLE_NAME="Daemon Light" V_VSCODE="Daemon-2.0 Light" ;;
        *) return 1 ;;
    esac
}

daemon_variant_of() {  # daemon_variant_of PACKAGE-ID : prints light or dark, or nothing for another theme
    case $1 in
        "$DAEMON_LNF_LIGHT") echo light ;;
        "$DAEMON_LNF_DARK")  echo dark ;;
    esac
}

daemon_current() {  # the variant of the active global theme, or nothing
    daemon_variant_of "$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)"
}

daemon_aurorae_library() {  # Plasma 6.6 draws SVG Aurorae themes with the .v2 plugin; older Plasma has only the first
    if ls /usr/lib/*/qt6/plugins/org.kde.kdecoration*/org.kde.kwin.aurorae.v2.so >/dev/null 2>&1; then
        echo org.kde.kwin.aurorae.v2
    else
        echo org.kde.kwin.aurorae
    fi
}

daemon_apply_global() { plasma-apply-lookandfeel -a "$V_LNF"; }

daemon_apply_konsole() {  # default profile for new windows, and every open Konsole tab switched live
    kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "$V_KONSOLE"
    local svc path
    for svc in $(busctl --user list --no-legend 2>/dev/null | awk '$1 ~ /^org\.kde\.konsole/ {print $1}'); do
        for path in $(busctl --user tree --list "$svc" 2>/dev/null | grep -E '^/Sessions/[0-9]+$'); do
            busctl --user call "$svc" "$path" org.kde.konsole.Session setProfile s "$V_KONSOLE_NAME" >/dev/null 2>&1 || true
        done
    done
}

daemon_apply_vscode() { python3 "$DAEMON_HOME/vscode/theme-setting.py" "$1" set "$V_VSCODE"; }   # $1 = settings.json

daemon_notify() {  # tell KWin and running applications that the look changed
    busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure >/dev/null 2>&1 || true
    local kind
    for kind in 1 2; do  # 1 = fonts changed, 2 = widget style changed
        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.notifyChange int32:$kind int32:0 2>/dev/null || true
    done
}
