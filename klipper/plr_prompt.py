# Power-loss recovery prompt for Creality KE/K1 with a non-stock screen.
#
# Stock Creality klipper already records the print state (EEPROM via
# bl24c16f + print_file_name.json) and knows how to restore it when started
# with "SDCARD_PRINT_FILE ... ISCONTINUEPRINT=1". The stock display-server
# used to ask the user and send that command; this module does the same via
# "action:prompt" dialogs, which Fluidd, Mainsail and GuppyScreen render.
#
# Copyright (C) 2026  jigurdas
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import os, json, logging

INFO_PATH = "/usr/data/creality/userdata/config/print_file_name.json"
REFER_PATH = "/usr/data/creality/userdata/config/user_print_refer.json"

class PLRPrompt:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.delay = config.getfloat('delay', 10., minval=0.)
        self.gcodes_dir = os.path.normpath(os.path.expanduser(config.get(
            'gcodes_dir', '/usr/data/printer_data/gcodes'))) + '/'
        self.printer.register_event_handler("klippy:connect",
                                            self._handle_connect)
        self.printer.register_event_handler("klippy:ready", self._handle_ready)
        self.gcode.register_command("PLR_CHECK", self.cmd_PLR_CHECK,
                                    desc="Ask to resume a power-lost print")
        self.gcode.register_command("PLR_RESUME", self.cmd_PLR_RESUME,
                                    desc="Resume a power-lost print")
        self.gcode.register_command("PLR_DISCARD", self.cmd_PLR_DISCARD,
                                    desc="Forget a power-lost print")
    def _handle_connect(self):
        # Creality's restore wraps its X/Y homing in SOFT_CHECK_ERROR, which
        # comes from soft_homing.py. Setups with their own homing (e.g. the
        # Helper Script's sensorless.cfg) don't load it, and the restore then
        # reports "Unknown command" twice. Provide a no-op in that case.
        try:
            self.gcode.register_command("SOFT_CHECK_ERROR",
                                        self.cmd_SOFT_CHECK_ERROR)
        except Exception:
            pass
    def cmd_SOFT_CHECK_ERROR(self, gcmd):
        pass
    def _handle_ready(self):
        # Ask twice in case the screen wasn't connected yet the first time;
        # a repeated prompt_begin just replaces the open dialog
        now = self.reactor.monotonic()
        for delay in (self.delay, self.delay + 45.):
            self.reactor.register_callback(self._check_cb, now + delay)
    def _check_cb(self, eventtime):
        try:
            self.gcode.run_script("PLR_CHECK")
        except Exception:
            logging.exception("plr_prompt: startup check failed")
    def _eeprom(self):
        return self.printer.lookup_object('bl24c16f', None)
    def _pending_file(self):
        # Returns the gcode path (relative to gcodes_dir) of an interrupted
        # print that can be resumed, or None.
        if not os.path.exists(INFO_PATH):
            return None
        try:
            with open(REFER_PATH, "r") as f:
                refer = json.loads(f.read())
            if not refer.get("power_loss", {}).get("switch", False):
                return None
            with open(INFO_PATH, "r") as f:
                path = json.loads(f.read()).get("file_path", "")
        except Exception:
            logging.exception("plr_prompt: can't read power loss info")
            return None
        if not path.startswith(self.gcodes_dir) or not os.path.exists(path):
            return None
        eeprom = self._eeprom()
        # checkEepromFirstEnable() is True when no position was saved
        if eeprom is None or eeprom.checkEepromFirstEnable():
            return None
        return path[len(self.gcodes_dir):]
    def _is_printing(self):
        vsd = self.printer.lookup_object('virtual_sdcard', None)
        return vsd is not None and vsd.is_active()
    def _prompt(self, lines):
        for line in lines:
            self.gcode.respond_raw("// action:" + line)
    def cmd_PLR_CHECK(self, gcmd):
        fname = self._pending_file()
        if fname is None or self._is_printing():
            gcmd.respond_info("PLR: no interrupted print")
            return
        # prompt_end first: GuppyScreen keeps old buttons until it sees one
        self._prompt([
            "prompt_end",
            "prompt_begin Power loss recovery",
            "prompt_text Print was interrupted: %s" % (fname,),
            "prompt_text Continue printing from where it stopped?",
            "prompt_footer_button Discard|PLR_DISCARD|error",
            "prompt_footer_button Resume|PLR_RESUME|primary",
            "prompt_show"])
    def cmd_PLR_RESUME(self, gcmd):
        self._prompt(["prompt_end"])
        fname = self._pending_file()
        if fname is None:
            raise gcmd.error("PLR: no interrupted print to resume")
        if self._is_printing():
            raise gcmd.error("PLR: printer is busy")
        gcmd.respond_info("PLR: resuming %s" % (fname,))
        # Call the handler directly so file names with spaces survive
        vsd = self.printer.lookup_object('virtual_sdcard')
        resume_cmd = self.gcode.create_gcode_command(
            "SDCARD_PRINT_FILE", "SDCARD_PRINT_FILE",
            {"FILENAME": fname, "ISCONTINUEPRINT": "1"})
        vsd.cmd_SDCARD_PRINT_FILE(resume_cmd)
    def cmd_PLR_DISCARD(self, gcmd):
        self._prompt(["prompt_end"])
        if self._is_printing():
            raise gcmd.error("PLR: printer is busy")
        for path in (INFO_PATH, getattr(self.gcode, 'exclude_object_info', None)):
            if path and os.path.exists(path):
                os.remove(path)
        eeprom = self._eeprom()
        if eeprom is not None:
            eeprom.setEepromDisable()
        os.system("sync")
        gcmd.respond_info("PLR: interrupted print discarded")

def load_config(config):
    return PLRPrompt(config)
