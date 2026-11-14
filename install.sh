#!/bin/bash
# install.sh - set up a fresh Qubes dom0 from this repo.
#
# Run in dom0, from a copy of the repo that you have READ first:
#   bash ~/import/qubes-i3/setup/install.sh [--dry-run] [--no-packages] [--no-etc] [-y]
#
# Repo layout it expects (anything missing is skipped):
#   config/   -> ~/.config/          local/  -> ~/.local/
#   home/     -> ~/   (dotfiles)     scripts/ -> ~/scripts/
#   etc/      -> /etc/ (sudo, with a protected-path blocklist)
#   setup/packages.txt  one dom0 (Fedora) package per line
#   setup/xfconf.txt    "channel property type value" per line
#
# Existing files that differ are moved to ~/.dom0-setup-backup/<timestamp>/
# before being replaced. Re-running is safe: unchanged files are skipped.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO/setup"
BACKUP="$HOME/.dom0-setup-backup/$(date +%Y%m%d-%H%M%S)"

DRY=0; DO_PKGS=1; DO_ETC=1; YES=0; FORCE=0
for a in "$@"; do
    case $a in
        --dry-run)     DRY=1 ;;
        --no-packages) DO_PKGS=0 ;;
        --no-etc)      DO_ETC=0 ;;
        -y|--yes)      YES=1 ;;
        --force)       FORCE=1 ;;   # skip the dom0 check (for testing only)
        -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" -eq 1 ]; then printf '   + %s\n' "$*"; else "$@"; fi; }
confirm() {
    [ "$YES" -eq 1 ] && return 0
    read -r -p "$1 [y/N] " ans; [[ $ans == [yY]* ]]
}

# qubes-dom0-update only exists in dom0, so this stops a run inside a qube.
if [ "$FORCE" -eq 0 ] && ! command -v qubes-dom0-update >/dev/null 2>&1; then
    die "This is not dom0 (qubes-dom0-update not found). Run it in dom0."
fi

FAILED=(); CHANGED=()

# ---- packages ---------------------------------------------------------------
install_packages() {
    local file="$SETUP/packages.txt" line p
    local -a want=() missing=()
    [ -f "$file" ] || { warn "no packages.txt, skipping packages"; return; }
    while IFS= read -r line; do
        line=${line%%#*}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && want+=("$line")
    done < "$file"
    for p in "${want[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ ${#missing[@]} -eq 0 ]; then log "All ${#want[@]} packages already installed"; return; fi

    log "Installing ${#missing[@]} package(s): ${missing[*]}"
    run sudo qubes-dom0-update "${missing[@]}" && return

    warn "Bulk install failed or was declined (one bad package name fails the lot)."
    confirm "Try each package on its own?" || { FAILED+=("${missing[@]}"); return; }
    for p in "${missing[@]}"; do
        run sudo qubes-dom0-update -y "$p" || FAILED+=("$p")
    done
}

# ---- file sync --------------------------------------------------------------
# sync_tree SRC DST [sudo]   copy every file under SRC to DST, backing up changes
SKIP_RE=''
sync_tree() {
    local src=$1 dst=$2 as=${3:-} f rel target
    [ -d "$src" ] || return 0
    while IFS= read -r -d '' f; do
        rel=${f#"$src"/}; target="$dst/$rel"
        if [ -n "$SKIP_RE" ] && [[ $target =~ $SKIP_RE ]]; then
            warn "protected path, skipping: $target"; continue
        fi
        if [ -e "$target" ] && cmp -s "$f" "$target"; then continue; fi
        if [ -e "$target" ]; then
            run $as mkdir -p "$BACKUP/$(dirname "$target")"
            run $as cp -p "$target" "$BACKUP/$target"
        fi
        if [ -n "$as" ]; then
            run sudo install -D -m 0644 -o root -g root "$f" "$target"
        else
            run mkdir -p "$(dirname "$target")"
            run cp -p "$f" "$target"
        fi
        CHANGED+=("$target")
    done < <(find "$src" -type f -not -path '*/.git/*' -print0)
}

sync_home() {
    sync_tree "$REPO/config"  "$HOME/.config"
    sync_tree "$REPO/local"   "$HOME/.local"
    sync_tree "$REPO/home"    "$HOME"
    sync_tree "$REPO/scripts" "$HOME/scripts"
}

sync_etc() {
    [ -d "$REPO/etc" ] || return 0
    log "Files that would go into /etc:"
    ( cd "$REPO/etc" && find . -type f -not -path '*/.git/*' | sed 's|^\.|  /etc|' )
    confirm "Apply these to /etc with sudo?" || { warn "skipped /etc"; return; }
    # Never let a repo overwrite files that can lock you out or break boot/policy.
    SKIP_RE='^/etc/(fstab|crypttab|sudoers|default/grub|grub\.d|qubes|qubes-rpc|polkit-1|pam\.d|ssh|shadow|passwd|group)'
    sync_tree "$REPO/etc" /etc sudo
    SKIP_RE=''
}

# ---- after-copy fixups ------------------------------------------------------
post_steps() {
    log "Fixing permissions, font and icon caches"
    if [ "$DRY" -eq 0 ]; then
        find "$HOME/scripts" "$HOME/.config/i3blocks" "$HOME/.config/i3" \
            -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null
        fc-cache -f >/dev/null 2>&1
        for d in "$HOME"/.local/share/icons/*/; do
            [ -f "${d}index.theme" ] && gtk-update-icon-cache -q "$d" 2>/dev/null
        done
    fi

    local file="$SETUP/xfconf.txt" ch prop type val
    if [ -f "$file" ]; then
        log "Applying XFCE settings from xfconf.txt"
        while read -r ch prop type val; do
            case $ch in ''|\#*) continue ;; esac
            run xfconf-query -c "$ch" -p "$prop" -n -t "$type" -s "$val" ||
                warn "could not set $ch $prop (needs a running session)"
        done < "$file"
    fi

    if [ "$DRY" -eq 0 ] && pgrep -x i3 >/dev/null 2>&1; then
        log "Reloading i3"; i3-msg reload >/dev/null 2>&1 || warn "i3 reload failed - check the config"
    fi
}

# ---- go ---------------------------------------------------------------------
[ "$DRY" -eq 1 ] && log "DRY RUN - nothing will be changed"
[ "$DO_PKGS" -eq 1 ] && install_packages
sync_home
[ "$DO_ETC" -eq 1 ] && sync_etc
post_steps

echo
log "Done. ${#CHANGED[@]} file(s) installed or updated."
[ -d "$BACKUP" ] && echo "   Previous versions saved in: $BACKUP"
if [ ${#FAILED[@]} -gt 0 ]; then
    warn "Packages that did not install: ${FAILED[*]}"
    echo "   Look up the real name with: sudo qubes-dom0-update --action=search <part-of-name>"
fi
cat <<'NOTE'

Not done by this script (they live outside dom0):
  - xclip in the template of each qube that should get screenshots on its clipboard
  - the qube that runs crypto.sh / weather scripts, plus any API keys
  - set a primary monitor if the tray is missing:  xrandr --output <name> --primary
NOTE
