#!/bin/bash
# screenshot.sh - dom0 screenshot tool for Qubes OS + i3
#
# Usage: screenshot.sh <screen|delay|window|select> <save|send|clip> [qube]
#
#   screen  focused monitor          delay   focused monitor after $DELAY s
#   window  active window            select  drag a region (Esc cancels)
#
#   save    keep the PNG in dom0 (~/Pictures/Screenshots)
#   send    move the PNG to a qube -> ~/QubesIncoming/dom0/ in that qube
#   clip    send it, then put it on that qube's clipboard (needs xclip in the
#           qube's template) - the Qubes replacement for the old *clip modes
#
# With no [qube], a picker opens with the qube you were working in listed first.
# With no args at all, the mode comes from the tmux session name like before
# (screensave, delaysave, windowclip, ...).

set -u
: "${DISPLAY:=:0}"; export DISPLAY
if [ -z "${I3SOCK:-}" ]; then
    I3SOCK="$(find "/run/user/$(id -u)/i3" -maxdepth 1 -type s -name 'ipc-socket.*' 2>/dev/null | sort | tail -n1)"
    export I3SOCK
fi

DIR="$HOME/Pictures/Screenshots"
LOG="$HOME/.cache/screenshot.log"
DELAY=3
mkdir -p "$DIR" "$(dirname "$LOG")"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
die() { notify-send "Screenshot failed" "$1"; log "ERROR: $1"; exit 1; }

# ---- arguments (or legacy tmux session name) --------------------------------
mode=${1:-}; action=${2:-}; target=${3:-}
if [ -z "$mode" ]; then
    s=$(tmux display-message -p '#S' 2>/dev/null)
    case $s in
        delay*)  mode=delay ;;  screen*) mode=screen ;;
        window*) mode=window ;; select*) mode=select ;;
    esac
    case $s in
        *save) action=save ;; *send) action=send ;; *clip) action=clip ;;
    esac
fi
[ -n "$mode" ] && [ -n "$action" ] ||
    die "usage: screenshot.sh <screen|delay|window|select> <save|send|clip> [qube]"
log "mode=$mode action=$action target=${target:-?}"

# ---- helpers ----------------------------------------------------------------
# Geometry (WxH+X+Y) of the monitor holding the focused workspace.
# Exact match on the output name, so DP-3 doesn't also match DP-3-1 on the dock.
focused_geometry() {
    local out
    out=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused).output')
    xrandr | awk -v o="$out" '$1 == o {
        for (i = 2; i <= NF; i++)
            if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { print $i; exit }
    }'
}

# Name of the qube owning the active window (empty for dom0 windows).
focused_qube() {
    [ -n "$win" ] || return
    xprop -id "$win" _QUBES_VMNAME 2>/dev/null | sed -n 's/.*= "\(.*\)"$/\1/p'
}

# Pick a target: hinted qube first, then other running qubes (no dom0/templates).
pick_qube() {
    local list
    list=$( { [ -n "$1" ] && echo "$1"
              qvm-ls --running --raw-data --fields NAME,CLASS |
                  awk -F'|' '$2 != "AdminVM" && $2 != "TemplateVM" { print $1 }' |
                  sort; } | awk 'NF && !seen[$0]++')
    if command -v rofi >/dev/null; then
        rofi -dmenu -i -p "Send screenshot to" <<< "$list"
    elif command -v dmenu >/dev/null; then
        dmenu -i -p "Send to:" <<< "$list"
    else
        # shellcheck disable=SC2086
        zenity --list --title="Send screenshot to" --column=Qube $list 2>/dev/null
    fi
}

# ---- capture ----------------------------------------------------------------
win=$(xdotool getactivewindow 2>/dev/null)
hint=$(focused_qube)          # read before the picker steals focus
file="$DIR/screenshot-$(date -u +%Y%m%d-%H%M%SZ).png"
name=$(basename "$file")

case $mode in
    screen|delay)
        geo=$(focused_geometry)
        [ -n "$geo" ] || die "Could not determine focused monitor"
        [ "$mode" = delay ] && sleep "$DELAY"
        maim --format=png --geometry="$geo" "$file" ;;
    window)
        [ -n "$win" ] || die "Could not determine active window"
        maim --format=png --window "$win" "$file" ;;
    select)
        maim --format=png --select "$file" ;;
    *)
        die "Unknown mode: $mode" ;;
esac 2>>"$LOG"

if [ ! -s "$file" ]; then
    rm -f "$file"
    [ "$mode" = select ] && exit 0      # Esc during selection: quiet cancel
    die "File was not created"
fi
log "captured $file (hint=${hint:-dom0})"

# ---- deliver ----------------------------------------------------------------
case $action in
    save)
        notify-send "Screenshot saved" "$name" ;;

    send|clip)
        [ -n "$target" ] || target=$(pick_qube "$hint")
        if [ -z "$target" ]; then
            notify-send "Screenshot kept in dom0" "$name"
            exit 0
        fi
        qvm-copy-to-vm "$target" "$file" 2>>"$LOG" ||
            die "Could not send to $target (kept in dom0: $name)"
        rm -f "$file"
        log "sent $name to $target"

        if [ "$action" = clip ]; then
            # xclip forks and keeps serving the image on the qube's clipboard
            qvm-run -q "$target" \
                "xclip -selection clipboard -t image/png -i ~/QubesIncoming/dom0/$name" 2>>"$LOG"
            notify-send "Screenshot on $target clipboard" "Paste with Ctrl+V in $target"
        else
            notify-send "Screenshot sent to $target" "~/QubesIncoming/dom0/$name"
        fi ;;

    *)
        die "Unknown action: $action" ;;
esac

exit 0
