#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Board selection by host USB port: FTDI chip (cable) autodetection from a fake sysfs tree.

import os
import tempfile
import unittest
from unittest import mock

import acorn_soc2soc
from litex_boards.platforms import sqrl_acorn

def fake_usb_device(sysfs, port, vid, pid, busnum, devnum):
    path = os.path.join(sysfs, port)
    os.makedirs(path)
    for name, value in [("idVendor", vid), ("idProduct", pid), ("busnum", busnum), ("devnum", devnum)]:
        with open(os.path.join(path, name), "w") as f:
            f.write(f"{value}\n")

class TestProgrammer(unittest.TestCase):
    def setUp(self):
        self.tmp   = tempfile.TemporaryDirectory()
        self.sysfs = self.tmp.name
        fake_usb_device(self.sysfs, "1-3", "0403", "6010", 1, 7)  # FT2232 baseboard.
        fake_usb_device(self.sysfs, "1-5", "0403", "6011", 1, 12) # FT4232 baseboard.
        fake_usb_device(self.sysfs, "1-6", "046d", "c52b", 1, 3)  # Not an FTDI chip.

    def tearDown(self):
        self.tmp.cleanup()

    def test_ftdi_chip_detected_per_port(self):
        self.assertEqual(acorn_soc2soc.usb_port_ftdi("1-3", sysfs=self.sysfs), (1, 7,  "ft2232"))
        self.assertEqual(acorn_soc2soc.usb_port_ftdi("1-5", sysfs=self.sysfs), (1, 12, "ft4232"))

    def test_unsupported_or_missing_device(self):
        with self.assertRaisesRegex(RuntimeError, "No supported FTDI chip"):
            acorn_soc2soc.usb_port_ftdi("1-6", sysfs=self.sysfs)
        with self.assertRaisesRegex(RuntimeError, "No USB device"):
            acorn_soc2soc.usb_port_ftdi("1-9", sysfs=self.sysfs)

    def test_programmer_command(self):
        platform = sqrl_acorn.Platform()
        real_usb_port_ftdi = acorn_soc2soc.usb_port_ftdi
        usb_port_ftdi = lambda port: real_usb_port_ftdi(port, sysfs=self.sysfs)
        with mock.patch.object(acorn_soc2soc, "usb_port_ftdi", usb_port_ftdi):
            prog = acorn_soc2soc.create_programmer(platform, "openfpgaloader", "1-5")
        self.assertEqual(prog.cmd, ["openFPGALoader", "--fpga-part", "xc7a200tfbg484",
            "--cable", "ft4232", "--freq", "10000000", "--busdev-num", "1:12"])
