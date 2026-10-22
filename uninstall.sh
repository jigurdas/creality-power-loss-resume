#!/bin/sh
set -eu

CONFIG_DIR="${1:-/usr/data/printer_data/config}"
PRINTER_CFG="$CONFIG_DIR/printer.cfg"
MOONRAKER_CFG="$CONFIG_DIR/moonraker.conf"
TARGET_CFG="$CONFIG_DIR/plr.cfg"
UPDATE_DIR="$CONFIG_DIR/creality-power-loss-resume"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root on the printer" >&2
    exit 1
fi
[ -f "$PRINTER_CFG" ] || { echo "Cannot find $PRINTER_CFG" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$CONFIG_DIR/power-loss-resume-backup-$STAMP-$$"
mkdir -p "$BACKUP_DIR"
cp -p "$PRINTER_CFG" "$BACKUP_DIR/printer.cfg"
[ ! -f "$MOONRAKER_CFG" ] || cp -p "$MOONRAKER_CFG" "$BACKUP_DIR/moonraker.conf"

# The include goes first so Klipper never sees [plr_prompt] without its module
TMP_PRINTER="$PRINTER_CFG.$$"
grep -Ev '^[[:space:]]*\[include[[:space:]]+plr\.cfg\][[:space:]]*$' "$PRINTER_CFG" > "$TMP_PRINTER" || true
mv "$TMP_PRINTER" "$PRINTER_CFG"
echo "Removed [include plr.cfg] from printer.cfg"

if [ -f "$TARGET_CFG" ]; then
    mv "$TARGET_CFG" "$BACKUP_DIR/plr.cfg"
    echo "Removed $TARGET_CFG"
fi

for dir in "${KLIPPER_EXTRAS:-}" /usr/share/klipper/klippy/extras "$HOME/klipper/klippy/extras"; do
    # -L as well: the installer symlinks into the checkout, which may be gone
    if [ -n "$dir" ] && { [ -f "$dir/plr_prompt.py" ] || [ -L "$dir/plr_prompt.py" ]; }; then
        [ ! -f "$dir/plr_prompt.py" ] || cp -p "$dir/plr_prompt.py" "$BACKUP_DIR/plr_prompt.py"
        rm -f "$dir/plr_prompt.py"
        echo "Removed $dir/plr_prompt.py"
    fi
done

if [ -f "$MOONRAKER_CFG" ] && grep -q '^\[update_manager creality-power-loss-resume\]' "$MOONRAKER_CFG"; then
    TMP_MOONRAKER="$MOONRAKER_CFG.$$"
    awk '
        $0 == "[update_manager creality-power-loss-resume]" { skip=1; next }
        skip && $0 ~ /^\[/ { skip=0 }
        !skip { print }
    ' "$MOONRAKER_CFG" > "$TMP_MOONRAKER"
    mv "$TMP_MOONRAKER" "$MOONRAKER_CFG"
    echo "Removed Update Manager entry"
fi

[ ! -d "$UPDATE_DIR" ] || { rm -rf "$UPDATE_DIR"; echo "Removed $UPDATE_DIR"; }

echo "Backup: $BACKUP_DIR"
echo "Restart the Klipper and Moonraker services."
