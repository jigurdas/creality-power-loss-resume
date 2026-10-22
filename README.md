# Creality Power Loss Resume

Brings back the "resume print after power loss?" question on Creality Klipper printers (Ender-3 V3 KE, K1 family) after the stock screen app was replaced by Guppy Screen, Fluidd or Mainsail.

## Why it stops working

Creality's Klipper already records the print state while printing (file position in the `bl24c16f` EEPROM plus `print_file_name.json`) and already knows how to restore it: heat the bed and nozzle, home **only X and Y**, restore the position, fan, speed and extrusion state, and print the first layers after the restore at 20% speed. All of that lives in Creality's `virtual_sdcard.py` and starts with:

```
SDCARD_PRINT_FILE FILENAME=<file> ISCONTINUEPRINT=1
```

The part that asks you after boot and sends that command is the stock screen app, `display-server`. Installing Guppy Screen disables it, so the saved state is never used. Fluidd and Mainsail have no power loss recovery of their own.

## What this adds

A small Klipper module, `plr_prompt.py`:

- After Klipper starts it checks for an interrupted print: power loss enabled in `user_print_refer.json`, a saved `print_file_name.json` pointing at an existing G-code file, and a saved position in the EEPROM.
- If it finds one, it shows a **Power loss recovery** dialog with **Resume** and **Discard** as Klipper `action:prompt`, which Guppy Screen, Fluidd and Mainsail all render. It asks 15 and 60 seconds after startup, so a screen that connects late still gets it.
- **Resume** runs Creality's own restore. **Discard** clears the saved state the way the stock firmware does when a print is cancelled.

Commands: `PLR_CHECK` (show the dialog if there is something to resume), `PLR_RESUME`, `PLR_DISCARD`, and the `POWER_LOSS_RESUME` macro, which shows up in macro lists as a manual way to open the dialog.

## Requirements

- Creality's Klipper with `bl24c16f.py` and a `virtual_sdcard.py` that supports `ISCONTINUEPRINT` (stock Ender-3 V3 KE / K1 firmware). The installer checks both.
- Power loss recovery switched on (`"power_loss": {"switch": true}` in `/usr/data/creality/userdata/config/user_print_refer.json`; it is on by default).
- Recording enabled in `virtual_sdcard.py`. Some mods disable the EEPROM writes by turning `if power_loss_switch and ...` into `if False and power_loss_switch and ...`. The installer warns when it sees that; nothing can be resumed until it is reverted.

## Installation

SSH into the printer and run:

```sh
git clone --depth=1 https://github.com/jigurdas/creality-power-loss-resume.git /tmp/plr && sh /tmp/plr/install.sh
```

The installer checks the firmware, backs up `printer.cfg` and `moonraker.conf`, installs `plr_prompt.py` into `klippy/extras` and `plr.cfg` into the config folder, adds `[include plr.cfg]`, registers the repository with Moonraker Update Manager, and restarts the Klipper and Moonraker services. If Klipper then reports that the MCU is shut down, run `FIRMWARE_RESTART` once.

A Creality firmware update replaces `klippy/extras` and removes `plr_prompt.py`. Run the installer again afterwards, or Klipper stops with an unknown `[plr_prompt]` section.

## Configuration

`plr.cfg`:

```ini
[plr_prompt]
# Seconds after Klipper is ready before the first check
delay: 15
# gcodes_dir: /usr/data/printer_data/gcodes
```

The installer keeps an existing `plr.cfg` on updates.

## Status and testing

Tested on an Ender-3 V3 KE with Guppy Screen: the power was cut at layer 8 of a small PLA print, the dialog appeared after boot, and **Resume** continued the print.

What the log of that test showed:

- The restore reported `Unknown command: SOFT_CHECK_ERROR` twice. Creality's restore wraps its X/Y homing in that command from `soft_homing.py`, which setups with their own homing (such as the Helper Script's `sensorless.cfg`) don't load. Since v0.1.2 the module provides a no-op `SOFT_CHECK_ERROR` when none exists.
- The part-cooling fan was restored to the last `M106` before the stop point (`M106 S125`). It stays off while the nozzle reheats and comes on just before homing.
- Creality's restore prints the next layer at 20% speed (`M220 S20`) and then returns to the previous speed; in the test that took about a minute. If it stays slow, set the speed back with `M220 S100`.

Before trusting it with a long print, run your own short test: start a small print, switch the power off after a few layers, switch it back on, press **Resume** and stay next to the printer. Z is not homed during the restore (the part is in the way): the first X/Y homing lifts Z by 5 mm, and the nozzle height comes from the saved position. Do not move Z by hand while the power is off.

## Uninstall

```sh
sh /usr/data/printer_data/config/creality-power-loss-resume/uninstall.sh
```

It backs up and removes the module, `plr.cfg`, the include line and the Update Manager entry. Restart the Klipper and Moonraker services afterwards.

## Development checks

```sh
./tests/validate.sh
```

## License

GPL-3.0, the same license as Klipper. See [LICENSE](LICENSE).
