#!/bin/sh
set -eu

REPO_URL="https://github.com/jigurdas/creality-power-loss-resume.git"
CONFIG_DIR="${CONFIG_DIR:-/usr/data/printer_data/config}"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
UPDATE_DIR="$CONFIG_DIR/creality-power-loss-resume"
TMP_REPO="$UPDATE_DIR.tmp.$$"
TMP_TARGET=""

cleanup() {
    rm -rf "$TMP_REPO"
    [ -z "$TMP_TARGET" ] || rm -f "$TMP_TARGET"
}
trap cleanup EXIT INT TERM
fail() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# Creality firmware keeps Klipper in /usr/share/klipper
find_klipper_extras() {
    for dir in "${KLIPPER_EXTRAS:-}" /usr/share/klipper/klippy/extras "$HOME/klipper/klippy/extras"; do
        if [ -n "$dir" ] && [ -f "$dir/gcode_macro.py" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

[ "$(id -u)" -eq 0 ] || fail "Run as root on the printer"

PRINTER_CFG="$CONFIG_DIR/printer.cfg"
MOONRAKER_CFG="$CONFIG_DIR/moonraker.conf"
[ -f "$PRINTER_CFG" ] || fail "Cannot find $PRINTER_CFG"

# Keep a git checkout in the config folder so Moonraker Update Manager can
# update it. Clone to a temporary path first so a failed network operation
# never deletes a working install.
case "$SELF_DIR" in
    "$UPDATE_DIR") ;;
    *)
        command -v git >/dev/null 2>&1 || fail "git is required"
        git clone --depth=1 "$REPO_URL" "$TMP_REPO"
        rm -rf "$UPDATE_DIR"
        mv "$TMP_REPO" "$UPDATE_DIR"
        exec env CONFIG_DIR="$CONFIG_DIR" sh "$UPDATE_DIR/install.sh"
        ;;
esac

EXTRAS_DIR="$(find_klipper_extras)" || fail "Cannot find klippy/extras; set KLIPPER_EXTRAS=/path/to/klippy/extras"
for f in virtual_sdcard.py bl24c16f.py; do
    [ -f "$EXTRAS_DIR/$f" ] || fail "$EXTRAS_DIR/$f is missing; this needs Creality's Klipper with power loss recovery"
done
grep -q 'ISCONTINUEPRINT' "$EXTRAS_DIR/virtual_sdcard.py" \
    || fail "This Klipper has no Creality power loss restore (ISCONTINUEPRINT)"
if grep -q 'if False and power_loss_switch' "$EXTRAS_DIR/virtual_sdcard.py"; then
    warn "Power loss recording is disabled in $EXTRAS_DIR/virtual_sdcard.py ('if False and power_loss_switch')."
    warn "The prompt will never find an interrupted print until that is reverted."
fi

TARGET_MODULE="$EXTRAS_DIR/plr_prompt.py"
TARGET_CFG="$CONFIG_DIR/plr.cfg"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$CONFIG_DIR/power-loss-resume-backup-$STAMP-$$"
mkdir -p "$BACKUP_DIR"
cp -p "$PRINTER_CFG" "$BACKUP_DIR/printer.cfg"
[ ! -f "$TARGET_CFG" ] || cp -p "$TARGET_CFG" "$BACKUP_DIR/plr.cfg"
[ ! -f "$TARGET_MODULE" ] || cp -p "$TARGET_MODULE" "$BACKUP_DIR/plr_prompt.py"
[ ! -f "$MOONRAKER_CFG" ] || cp -p "$MOONRAKER_CFG" "$BACKUP_DIR/moonraker.conf"

# The module goes first: plr.cfg's [plr_prompt] section needs it. It is a
# symlink into the Update Manager checkout, so an update from Fluidd or
# Mainsail (git pull, then a Klipper service restart by Moonraker) applies
# it; Moonraker does not run this script on updates.
TMP_TARGET="$TARGET_MODULE.$$"
ln -s "$UPDATE_DIR/klipper/plr_prompt.py" "$TMP_TARGET"
mv -f "$TMP_TARGET" "$TARGET_MODULE"
# Keep a user-edited plr.cfg (e.g. a changed delay) on updates
if [ ! -f "$TARGET_CFG" ]; then
    TMP_TARGET="$TARGET_CFG.$$"
    cp "$SELF_DIR/klipper/plr.cfg" "$TMP_TARGET"
    mv "$TMP_TARGET" "$TARGET_CFG"
fi
TMP_TARGET=""

if ! grep -Eq '^[[:space:]]*\[include[[:space:]]+plr\.cfg\][[:space:]]*$' "$PRINTER_CFG"; then
    printf '\n[include plr.cfg]\n' >> "$PRINTER_CFG"
fi

if [ -f "$MOONRAKER_CFG" ] && ! grep -q '^\[update_manager creality-power-loss-resume\]' "$MOONRAKER_CFG"; then
    cat >> "$MOONRAKER_CFG" <<EOF

[update_manager creality-power-loss-resume]
type: git_repo
channel: stable
path: $UPDATE_DIR
origin: $REPO_URL
primary_branch: main
install_script: install.sh
managed_services: klipper
info_tags:
    desc=Power loss recovery prompt for Creality printers without the stock screen
EOF
fi

# Creality's init scripts restart with "stop; sleep 1; start", and start
# refuses to run while the old process is still exiting, which leaves the
# service down. Stop, wait for the pid to go away, then start.
restart_initd() {
    script="$1"
    pidfile="$2"
    "$script" stop || true
    tries=0
    while [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -le 30 ] || return 1
        sleep 1
    done
    "$script" start
}

restart_service() {
    service_name="$1"
    if [ "$service_name" = klipper ] && [ -x /etc/init.d/S55klipper_service ]; then
        /etc/init.d/S55klipper_service restart
    elif [ "$service_name" = moonraker ] && [ -x /etc/init.d/S56moonraker_service ]; then
        restart_initd /etc/init.d/S56moonraker_service /var/run/moonraker.pid
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$service_name"
    else
        warn "No service manager found; restart $service_name manually"
    fi
}

restart_service klipper || fail "Klipper restart failed; restore the backup in $BACKUP_DIR before retrying"
[ ! -f "$MOONRAKER_CFG" ] || restart_service moonraker || fail "Moonraker restart failed; restore the backup in $BACKUP_DIR before retrying"

echo "Power loss resume prompt installed"
echo "Klipper module: $TARGET_MODULE"
echo "Config: $TARGET_CFG"
echo "Backup: $BACKUP_DIR"
echo "If Klipper reports that the MCU is shut down, run FIRMWARE_RESTART once."
