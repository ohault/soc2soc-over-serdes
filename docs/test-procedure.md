# Build and test procedure

This procedure goes from a fresh install to a validated SoC-to-SoC link in each of the three
scenarios. Run the steps in order: each scenario relies on the previous one passing.

| Step | What | Hardware |
|------|------|----------|
| [0](#0-install) | Install LiteX and Vivado | – |
| [1](#1-simulation) | Simulation of the link layer + SerWB | – |
| [2](#2-scenario-1-single-board-sfp0--sfp1) | Scenario 1: single board, SFP0 ⇄ SFP1 | 1 board, 1 DAC |
| [3](#3-scenario-2-two-boards-sfp0--sfp0) | Scenario 2: two boards, SFP0 ⇄ SFP0 | 2 boards, 1 DAC |
| [4](#4-scenario-3-two-boards-sfp0--sfp0-and-sfp1--sfp1) | Scenario 3: two boards, both SFPs | 2 boards, 2 DACs |
| [5](#5-optional-line-rate-and-crc) | Optional: higher line rates, CRC | as above |

[Troubleshooting](#troubleshooting) and a [results template](#results-template) are at the end.

All commands are run from the repository root.

## 0. Install

1. Install Vivado (any recent version that supports the Artix-7 XC7A200T) and make it available in
   your `PATH`, e.g. `source /opt/Xilinx/Vivado/<version>/settings64.sh`.
2. Install LiteX, its cores and the RISC-V toolchain (for the CPU/BIOS):

   ```sh
   wget https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py
   python3 litex_setup.py --init --install --user --config=standard
   pip3 install --user meson ninja
   python3 litex_setup.py --gcc=riscv
   ```

   `litex_setup.py` installs the official Migen from git.m-labs.hk. Do not install Migen from the
   old GitHub copy (see [Migen version](../README.md#migen-version)).
3. Install [openFPGALoader](https://github.com/trabucayre/openFPGALoader), used to load the
   bitstreams over the baseboard's JTAG.
4. Clone this repository:

   ```sh
   git clone https://github.com/ohault/soc2soc-over-serdes
   cd soc2soc-over-serdes
   ```

## 1. Simulation

This step needs no hardware. It checks the link layer and SerWB on top of it, with two simulated
link ends connected back to back.

```sh
python3 -m unittest test.test_link -v
```

**Pass:** the 4 tests (`test_link`, `test_link_byte_shift`, `test_link_crc`,
`test_link_error_recovery`) report `ok`. This takes about one minute.

## 2. Scenario 1: single board, SFP0 ⇄ SFP1

**Setup:** one Baseboard Mini with the Acorn CLE-215+. Connect one DAC cable between SFP0 and SFP1,
and the board's USB cable (JTAG + UART) to the host.

### 2.1 Build

```sh
./acorn_soc2soc.py --sfp0=initiator --sfp1=target --build
```

Output goes to `build/sqrl_acorn/`.

- **Pass:** the build finishes, `build/sqrl_acorn/gateware/sqrl_acorn.bit` exists, and Vivado reports
  that timing is met.
- **Timing:** check `build/sqrl_acorn/gateware/sqrl_acorn_timing.rpt`. Look for "All user specified
  timing constraints are met".
- **If the CPU/BIOS build fails:** rebuild without a CPU by adding
  `--cpu-type=None --uart-name=uartbone`. All tests below still work, since they run from the host.

### 2.2 Load

```sh
./acorn_soc2soc.py --sfp0=initiator --sfp1=target --load
```

This loads the bitstream into the FPGA's SRAM, so it is lost at power-off. To store it in the SPI
flash instead, use `--flash`.

**Pass:** check the LEDs on the Acorn module.

| LED | Expected |
|-----|----------|
| LED0 | Blinking (sys heartbeat) |
| LED3 | On (GTP QPLL locked) |
| LED1, LED2 | On (SFP0 and SFP1 links ready), possibly only after step 2.4 |

### 2.3 Connect the host

Start `litex_server` on the board's UART. With an FTDI dual or quad chip, this is usually the
second `/dev/ttyUSBx`:

```sh
litex_server --uart --uart-port=/dev/ttyUSB1
```

Keep it running and use a second terminal for the tests. All test commands below take
`--csr-csv=build/sqrl_acorn/csr.csv`. The BIOS console is available with `litex_term crossover`.

```sh
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv ident
```

**Pass:** this prints `LiteX SoC2SoC over SerDes on Acorn Baseboard Mini (SFP0: initiator / SFP1: target) ...`.

### 2.4 Polarity

```sh
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv autopolarity
```

**Pass:** this prints `RX OK with rx_polarity=X` for `sfp0` and `sfp1`, then `link ready: 1` for both.

If a polarity differs from the default (SFP0 RX=1, SFP1 RX=1), note it and add it to every later
build. For example, if SFP1 needs `rx_polarity=0`, add `--sfp1-rx-polarity=0`. These values are
properties of the board, so they also apply in scenarios 2 and 3.

### 2.5 Status

```sh
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv status
```

**Pass**, for both `sfp0` and `sfp1`:

| Field | Expected |
|-------|----------|
| GTP TX ready, GTP RX ready | 1 |
| TX/RX clk | ≈ 125 MHz (line rate / 20; 2.5 Gbps by default) |
| RX OK, Remote OK, Link ready | 1 |
| RX errors, Link drops, RX overflow, SerWB overflows | 0 |

Run `status` again after a minute: the error and link drop counters must not increase.

### 2.6 PRBS / bit error rate

```sh
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv prbs --duration=300
```

This sends a PRBS31 pattern in both directions (`sfp0→sfp1` and `sfp1→sfp0`) and counts bit
errors. While it runs the links are down; they come back up at the end of the test.

**Pass:** 0 errors in both directions. After 300 s at 2.5 Gbps, 0 errors means a BER below
1.3e-12.

### 2.7 Remote access

```sh
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv remote
```

This works through the SFP0 initiator window: it reads the SoC's own identifier through the cable,
then writes and reads back 256 random words in the mailbox.

**Pass:** `remote identifier: LiteX SoC2SoC ...` and `remote mailbox write/read of 256 words: 0 errors`.

### 2.8 Robustness (optional)

1. Unplug the DAC cable. LED1 and LED2 go off. In `status`, `Link ready` is 0.
2. Plug the cable back in. The LEDs come back on and `Link drops` has increased.
3. `remote` passes again.

## 3. Scenario 2: two boards, SFP0 ⇄ SFP0

**Setup:** boards A and B, with one DAC cable between A.SFP0 and B.SFP0, and both USB cables
connected to the host.

### 3.1 Build

Add the polarity options found in step 2.4, if any.

```sh
./acorn_soc2soc.py --sfp0=initiator --output-dir=build/board_a --build
./acorn_soc2soc.py --sfp0=target    --output-dir=build/board_b --build
```

### 3.2 Load

The programmer uses the first FTDI device it finds. Load each board **with only that board's USB
cable plugged in**:

```sh
./acorn_soc2soc.py --sfp0=initiator --output-dir=build/board_a --load   # Only board A plugged.
./acorn_soc2soc.py --sfp0=target    --output-dir=build/board_b --load   # Only board B plugged.
```

You can also call openFPGALoader directly and select each board with `--ftdi-serial`.

Alternatively, flash each board once with `--flash` instead of `--load`; the design then survives
power cycles.

**Pass:**
- **Board A:** LED0 blinks, LED3 is on, LED1 (SFP0 link) is on.
- **Board B:** same LEDs as board A.

### 3.3 Connect the host

Start one `litex_server` per board, on different ports. Use `ls /dev/ttyUSB*` before and after
plugging each board to find its UART.

```sh
litex_server --uart --uart-port=/dev/ttyUSB1 --bind-port=1234   # Board A
litex_server --uart --uart-port=/dev/ttyUSB3 --bind-port=1235   # Board B
```

For readability, define the test options once:

```sh
T="./test_soc2soc.py --csr-csv=build/board_a/csr.csv --port=1234 --peer-csr-csv=build/board_b/csr.csv --peer-port=1235"
```

### 3.4 Tests

```sh
$T ident              # Pass: board A ident shows SFP0: initiator, board B shows SFP0: target.
$T autopolarity       # Pass: local.sfp0 and peer.sfp0 RX OK, link ready: 1.
$T status             # Pass: same criteria as 2.5, for local.sfp0 and peer.sfp0.
$T prbs --duration=300  # Pass: 0 errors for local.sfp0->peer.sfp0 and peer.sfp0->local.sfp0.
$T remote             # Pass: remote identifier is board B's; mailbox 0 errors; direct check 0 errors.
```

The two boards run on separate oscillators, so in `status` their TX clocks differ slightly. That
is expected: the difference is absorbed by the clock-domain-crossing FIFOs. Also run the
robustness check (2.8) on this link.

## 4. Scenario 3: two boards, SFP0 ⇄ SFP0 and SFP1 ⇄ SFP1

**Setup:** as in scenario 2, plus a second DAC cable between A.SFP1 and B.SFP1.

### 4.1 Build and load

Add the polarity options found in step 2.4, if any.

```sh
./acorn_soc2soc.py --sfp0=initiator --sfp1=target    --output-dir=build/board_a --build
./acorn_soc2soc.py --sfp0=target    --sfp1=initiator --output-dir=build/board_b --build
```

Load as in 3.2, with the same role options.

**Pass:** on both boards, LED0 blinks and LED1, LED2 and LED3 are on.

### 4.2 Tests

Use the same `litex_server` setup and `$T` as in 3.3.

```sh
$T ident
$T autopolarity       # Pass: all 4 RX ends OK (local/peer sfp0/sfp1).
$T status             # Pass: same criteria as 2.5, for all 4 ends.
$T prbs --duration=300  # Pass: 0 errors on all 4 directions.
$T remote             # Pass: local.sfp0 reaches board B, peer.sfp1 reaches board A, 0 errors.
```

In `remote`, board A accesses board B through A.SFP0, and board B accesses board A through B.SFP1:
each board can access the other.

## 5. Optional: line rate and CRC

Repeat steps 2.5 to 2.7 (or 3.4) with other settings. Both ends of a link must be built with the
same options, and `prbs` needs the matching `--linerate` so the BER is computed correctly.

| Build options | TX/RX clk | `prbs` option |
|---------------|-----------|---------------|
| `--linerate=1.25e9` | 62.5 MHz | `--linerate=1.25e9` |
| `--refclk-freq=156.25e6 --linerate=3.125e9` | 156.25 MHz | `--linerate=3.125e9` |
| `--linerate=5e9` | 250 MHz, check timing | `--linerate=5e9` |
| `--with-crc` | unchanged | – |

At 5 Gbps the GTP reference clock comes from the fabric PLL, so it is more jittery. A non-zero BER
at that rate is a limitation of the board's clocking, not necessarily a bug.

## Troubleshooting

| Symptom | Likely cause / action |
|---------|-----------------------|
| LED3 off (QPLL not locked) | The refclk/line rate combination is invalid: check the `GTPQuadPLL` configuration printed during the build. GTP TX/RX ready then stay at 0. |
| `GTP TX ready` or `GTP RX ready` is 0 | QPLL not locked (see above), or the GTP is held in reset (`sfpN_serdes_tx_enable` / `rx_enable` CSRs at 0). |
| `autopolarity` fails with both polarities | No valid signal received. Check that the cable is fully inserted and that the remote end is loaded and built with the same line rate. Retry at `--linerate=1.25e9`. |
| `RX OK` is 1 but `Remote OK` is 0 | This side receives, but the other direction is broken: check the remote end's RX (its polarity and its `status`). |
| `RX errors` or `Link drops` increase | Marginal signal quality. Run `prbs`, try a lower line rate or another cable, or tune the TX drive (`sfpN_serdes_tx_diffctrl`, `sfpN_serdes_tx_postcursor` CSRs). |
| PRBS errors in one direction only | Check that direction's cable end and its TX/RX electrical settings. |
| `remote`: "link not ready, skipping" | The link is down: fix `status` first. |
| `remote`: wrong data or a bus error | Check `SerWB overflows` / `RX errors` in `status`, and rebuild with `--with-crc` to detect corrupted packets. |
| `litex_server` gets no response | Wrong `/dev/ttyUSBx`, or the board is not loaded. Check that LED0 blinks. |
| Loading programs the wrong board | Only plug in the board being loaded (see 3.2), or use openFPGALoader `--ftdi-serial`. |
| Simulation fails with `AttributeError: 'NoneType' object has no attribute 'eq'` in your own designs | Stale GitHub Migen: install the official one (see [Migen version](../README.md#migen-version)). |

When reporting a problem, include the output of `status` for every end of the link and the Vivado
timing summary.

## Results template

Copy this into an issue or pull request comment to record a test campaign.

```markdown
### SoC2SoC test results

- Date / commit:
- Boards (serials) / Acorn variant:
- DAC cables (vendor, length):
- Vivado version / LiteX commit:
- Polarities used (SFP0 TX/RX, SFP1 TX/RX):

| Step | Scenario | Line rate | Result | Notes |
|------|----------|-----------|--------|-------|
| 1    | Simulation | – | | |
| 2.1  | 1 Build / timing | 2.5G | | |
| 2.4  | 1 autopolarity | 2.5G | | |
| 2.5  | 1 status | 2.5G | | |
| 2.6  | 1 PRBS31 300s (errors / BER) | 2.5G | | |
| 2.7  | 1 remote | 2.5G | | |
| 2.8  | 1 unplug/replug | 2.5G | | |
| 3.4  | 2 status / PRBS / remote | 2.5G | | |
| 4.2  | 3 status / PRBS / remote | 2.5G | | |
| 5    | Line rate / CRC variants | | | |
```
