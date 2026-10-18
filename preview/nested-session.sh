#!/usr/bin/env bash
# Library: an isolated, throwaway Plasma 6 session for testing the theme without touching your desktop.
# Source it (see verify.sh). The session has its own D-Bus daemon, home, config, data and cache folders,
# a virtual-display KWin and a Plasma shell.
#
#   nest_start      start bus + KWin + Plasma shell, set the environment in the calling shell
#   nest_restart    stop and start KWin + shell (what logging out and in does; needed for the title font)
#   nest_app CMD..  start an application inside the session
#   nest_shot NAME  screenshot the whole virtual display to $NEST/shots/NAME.png
#   nest_arrange    tile Dolphin / System Settings / KCalc / Konsole for a tidy screenshot
#   nest_stop       stop everything that belongs to the session
#
# Two traps this file avoids (both happened while writing it, see ../CLAUDE.md):
#  - The private dbus-daemon must be started AFTER HOME/XDG_*/WAYLAND_DISPLAY point at the session:
#    services it auto-starts (kded6, portals, ksecretd...) inherit its environment, so a bus started
#    earlier would run them with your real home and your real display.
#  - kwin_wayland has a file capability (cap_sys_nice), which makes /proc/PID/environ unreadable, so it
#    cannot be found by environment. It is tracked by its unique --socket argument instead.
# Kvantum is not installed on this machine, so if `kvantummanager` is missing the .deb files are
# downloaded (apt-get download, no root) and unpacked into $NEST/kvroot, used only by the session.

NEST="${NEST:-${TMPDIR:-/tmp}/daemon-preview-$(id -u)}"
NEST_SOCKET=daemon-nest-$(id -u)
NEST_W=${NEST_W:-1920} NEST_H=${NEST_H:-1080}
KUBUNTU_DEFAULTS=$( [[ -d /usr/share/kubuntu-default-settings/kf5-settings ]] && echo /usr/share/kubuntu-default-settings/kf5-settings )

nest_env() {  # everything except the bus address, which exists only once the bus is started
    export HOME="$NEST/home" XDG_CONFIG_HOME="$NEST/config" XDG_DATA_HOME="$NEST/data"
    export XDG_CACHE_HOME="$NEST/cache" XDG_STATE_HOME="$NEST/state"
    # what startplasma sets: global themes write their values into ~/.config/kdedefaults, read through this
    export XDG_CONFIG_DIRS="$XDG_CONFIG_HOME/kdedefaults:/etc/xdg${KUBUNTU_DEFAULTS:+:$KUBUNTU_DEFAULTS}"
    export XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true XDG_SESSION_TYPE=wayland
    export WAYLAND_DISPLAY=$NEST_SOCKET QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 GTK_USE_PORTAL=0
    export DAEMON_BACKUP_ROOT="$NEST/backup"
    if [[ -d $NEST/kvroot ]]; then
        export PATH="$NEST/kvroot/usr/bin:$PATH" QT_PLUGIN_PATH="$NEST/kvroot/usr/lib/x86_64-linux-gnu/qt6/plugins"
    fi
    unset SESSION_MANAGER DISPLAY DBUS_SESSION_BUS_ADDRESS
    ulimit -c 0   # systemd-coredump honours this, so a crash in the session is not stored or reported
}

nest_kwin_pids() {  # the session's compositor(s), found by the socket name only this harness uses
    local p
    for p in $(pgrep -x kwin_wayland); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--socket=$NEST_SOCKET " && echo "$p"
    done
}

nest_pids() {  # every process on the session's private bus (readable environment), plus its compositor
    local want d pid comm
    want="DBUS_SESSION_BUS_ADDRESS=$(cat "$NEST/bus.addr" 2>/dev/null)"
    if [[ $want != "DBUS_SESSION_BUS_ADDRESS=" ]]; then
        for d in /proc/[0-9]*; do
            pid=${d#/proc/}
            [[ $pid -eq $$ || $pid -eq $BASHPID ]] && continue
            { tr '\0' '\n' < "$d/environ" | grep -qxF "$want"; } 2>/dev/null || continue
            comm=$(cat "$d/comm" 2>/dev/null)
            case $comm in bash|sh|python3|tr|grep|awk|sed|cat|sleep|timeout|verify.sh|busctl|spectacle) continue ;; esac
            echo "$pid"
        done
    fi
    nest_kwin_pids
}

nest_pids_named() {  # nest_pids_named COMM... : session PIDs whose process name is one of COMM
    local p c want=" $* "
    for p in $(nest_pids); do c=$(cat "/proc/$p/comm" 2>/dev/null); [[ $want == *" $c "* ]] && echo "$p"; done
}

nest_wait_gone() {  # nest_wait_gone SECONDS PID... : wait until all PIDs have exited
    local t=$1 p i; shift
    for ((i = 0; i < t * 2; i++)); do
        for p in "$@"; do kill -0 "$p" 2>/dev/null && { sleep 0.5; continue 2; }; done
        return 0
    done
    return 1
}

nest_has_name() { busctl --user list --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

nest_wait_name() {  # nest_wait_name NAME [seconds]
    local i
    for ((i = 0; i < ${2:-30} * 2; i++)); do nest_has_name "$1" && return 0; sleep 0.5; done
    return 1
}

nest_compositor() {
    if [[ -n $(nest_kwin_pids) ]] || nest_has_name org.kde.KWin; then
        echo "a session compositor is still running; not starting a second one" >&2; return 1
    fi
    rm -f "$XDG_RUNTIME_DIR/$NEST_SOCKET" "$XDG_RUNTIME_DIR/$NEST_SOCKET.lock"
    setsid nohup kwin_wayland --virtual --socket="$NEST_SOCKET" --width "$NEST_W" --height "$NEST_H" \
        --no-lockscreen --no-global-shortcuts > "$NEST/kwin.log" 2>&1 &
    nest_wait_name org.kde.KWin 30 || { echo "session KWin did not start; see $NEST/kwin.log" >&2; return 1; }
    local i; for ((i = 0; i < 40; i++)); do [[ -S $XDG_RUNTIME_DIR/$NEST_SOCKET ]] && break; sleep 0.5; done
    [[ -S $XDG_RUNTIME_DIR/$NEST_SOCKET ]] || { echo "session KWin has no display socket; see $NEST/kwin.log" >&2; return 1; }
    setsid nohup plasmashell --no-respawn > "$NEST/plasma.log" 2>&1 &
    nest_wait_name org.kde.plasmashell 40 || { echo "session Plasma shell did not start; see $NEST/plasma.log" >&2; return 1; }
    sleep 7
}

nest_start() {
    [[ -z $(nest_kwin_pids) ]] || { echo "a previous test session is still running (kwin $(nest_kwin_pids | tr '\n' ' '))" >&2; return 1; }
    rm -rf "$NEST"; mkdir -p "$NEST"/{home,config,data,cache,state,shots,backup}
    if ! command -v kvantummanager >/dev/null; then
        mkdir -p "$NEST/kvdeb" "$NEST/kvroot"
        ( cd "$NEST/kvdeb" && apt-get download qt-style-kvantum qt-style-kvantum-themes >/dev/null 2>&1 ) || true
        for d in "$NEST"/kvdeb/*.deb; do [[ -f $d ]] && dpkg-deb -x "$d" "$NEST/kvroot"; done
    fi
    nest_env                                                     # first the environment...
    dbus-daemon --session --fork --print-address=1 --print-pid=2 > "$NEST/bus.addr" 2> "$NEST/bus.pid"
    export DBUS_SESSION_BUS_ADDRESS="$(cat "$NEST/bus.addr")"    # ...then the bus, which inherits it
    nest_compositor || return 1
    # mimic this machine's stock look: Breeze Dark, breeze-dark icons, Kubuntu Dark shell, Breeze widgets
    plasma-apply-colorscheme BreezeLight >/dev/null 2>&1; plasma-apply-colorscheme BreezeDark >/dev/null 2>&1
    plasma-apply-desktoptheme kubuntu-dark >/dev/null 2>&1
    "$(ls /usr/lib/*/libexec/plasma-changeicons | head -1)" breeze-dark >/dev/null 2>&1
    kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle Breeze
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library org.kde.breeze
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme Breeze
    mkdir -p "$HOME"/{Documents,Downloads,Music,Pictures,Videos,Projects}
    echo hello > "$HOME/notes.txt"; touch "$HOME/report.pdf" "$HOME/archive.zip" "$HOME/script.sh"
}

nest_kill_clients() {  # close only the sample applications (their helpers exit with them); the shell keeps running
    local p; local -a apps
    mapfile -t apps < <(nest_pids_named dolphin kcalc konsole systemsettings)
    for p in "${apps[@]}"; do kill "$p" 2>/dev/null; done
    (( ${#apps[@]} )) && nest_wait_gone 10 "${apps[@]}"
    sleep 1
}

nest_kill_session() {  # shell, then every other client, compositor LAST; SIGKILL only for stragglers
    # Order matters: a Qt program on Wayland aborts (SIGABRT, which Apport reports) when its compositor
    # goes away, so the portals, kded6 and friends must be gone before KWin is stopped.
    local p i kw; local -a pl
    mapfile -t pl < <(nest_pids_named plasmashell); for p in "${pl[@]}"; do kill "$p" 2>/dev/null; done
    (( ${#pl[@]} )) && nest_wait_gone 10 "${pl[@]}"
    kw=" $(nest_kwin_pids | tr '\n' ' ') "
    pl=(); for p in $(nest_pids); do [[ $kw == *" $p "* ]] || pl+=("$p"); done
    for p in "${pl[@]}"; do kill "$p" 2>/dev/null; done
    (( ${#pl[@]} )) && nest_wait_gone 10 "${pl[@]}"
    mapfile -t pl < <(nest_kwin_pids);              for p in "${pl[@]}"; do kill "$p" 2>/dev/null; done
    (( ${#pl[@]} )) && nest_wait_gone 10 "${pl[@]}"
    for p in $(nest_pids); do kill -9 "$p" 2>/dev/null; done
    for ((i = 0; i < 20; i++)); do nest_has_name org.kde.KWin || break; sleep 0.5; done
}

nest_restart() {  # like logging out and in
    nest_kill_clients
    nest_kill_session
    nest_compositor
}

nest_app() { setsid nohup "$@" >> "$NEST/apps.log" 2>&1 & }

nest_shot() { ( cd "$NEST/shots" && timeout 30 spectacle -b -f -n -o "$1.png" >/dev/null 2>&1 ); [[ -s $NEST/shots/$1.png ]]; }

nest_arrange() {
    cat > "$NEST/arrange.js" <<'JS'
var pos = { "Dolphin":[30,40,880,560], "System Settings":[560,120,1320,760], "KCalc":[30,620,420,400], "Konsole":[470,880,1000,140] };
for (const w of workspace.windowList()) {
  for (const k in pos) if (w.caption.indexOf(k) >= 0 && w.normalWindow) { var p = pos[k]; w.frameGeometry = {x:p[0], y:p[1], width:p[2], height:p[3]}; }
}
JS
    local id
    id=$(busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss "$NEST/arrange.js" arrange_once | awk '{print $2}')
    busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run > /dev/null
    sleep 1
    busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s arrange_once > /dev/null
}

nest_stop() {
    nest_kill_clients
    nest_kill_session
    [[ -f $NEST/bus.pid ]] && kill "$(cat "$NEST/bus.pid")" 2>/dev/null
    rm -f "$XDG_RUNTIME_DIR/$NEST_SOCKET" "$XDG_RUNTIME_DIR/$NEST_SOCKET.lock"
    local left; left=$(nest_kwin_pids)
    [[ -z $left ]] || echo "warning: session compositor still running: $left" >&2
}
