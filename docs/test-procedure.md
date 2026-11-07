# Build and test procedure

This procedure goes from a fresh install to a validated SoC-to-SoC link in each of the three
scenarios. Run the steps in order: each scenario relies on the previous one passing.

All boards run **the same gateware** (SFP0 = initiator, SFP1 = target) and **every DAC cable joins
an SFP0 to an SFP1**. Going from one scenario to another only means moving cables: no rebuild, no
reload, and the test tool detects the cabling by itself.

| Step | What | Hardware |
|------|------|----------|
| [0](#0-install) | Install LiteX and Vivado | – |
| [1](#1-simulation) | Simulation: link layer, SerWB, bandwidth of each scenario | – |
| [2](#2-build-and-load) | Build once, load or flash every board | 1 or 2 boards |
| [3](#3-host-setup) | Host setup: board A/B, UARTs, `litex_server` | 1 or 2 boards |
| [4](#4-scenario-1-sfp0--sfp1-on-each-board) | Scenario 1: A.SFP0 ⇄ A.SFP1 (and B.SFP0 ⇄ B.SFP1) | 1 DAC per board |
| [5](#5-scenarios-2-and-3-between-boards) | Scenarios 2 and 3: A.SFP0 ⇄ B.SFP1 (and B.SFP0 ⇄ A.SFP1) | 2 boards, 1 or 2 DACs |
| [6](#6-optional-line-rate-and-crc) | Optional: other line rates, CRC | as above |

The [cabling](#cabling) rules come first. [Troubleshooting](#troubleshooting) and a
[results template](#results-template) are at the end.

All commands are run from the repository root.

## Cabling

- Use passive SFP+ DAC (direct-attach copper) cables. A DAC cable crosses TX and RX internally, so
  either end can go into either cage. No adapter or loopback plug is needed.
- **Every cable joins an SFP0 (initiator) to an SFP1 (target)**, on the same board or on the other
  one. A cable between two SFP0 or two SFP1 brings the link up, but remote access does not work
  (`wiring` reports it).
- Each board also needs its USB cable to the host (JTAG + UART), always on the same host USB port
  (see [3](#3-host-setup)).

```
Scenario 1:   A.SFP0 (initiator) ══ DAC ══ A.SFP1 (target)       A accesses A
  (and/or)    B.SFP0 (initiator) ══ DAC ══ B.SFP1 (target)       B accesses B

Scenario 2:   A.SFP0 (initiator) ══ DAC ══ B.SFP1 (target)       A accesses B

Scenario 3:   A.SFP0 (initiator) ══ DAC ══ B.SFP1 (target)       A accesses B
              B.SFP0 (initiator) ══ DAC ══ A.SFP1 (target)       B accesses A
```

From scenario 1 on both boards to scenario 3, unplug the SFP1 end of each cable and plug it into
the SFP1 of the other board. For scenario 2, remove the B.SFP0 cable. SFPs left without a cable
are reported as `not connected` and ignored.

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

This step needs no hardware. The transceivers are replaced by direct connections.

```sh
python3 -m unittest test.test_link -v    # Link layer + SerWB, a few seconds.
python3 -m unittest test.test_bench -v   # Bandwidth/latency of each scenario, about one minute.
```

**Pass:**
- `test_link`: the 7 tests report `ok`. The two `test_single_soc_*` tests model scenario 1, where
  the host and the SFP1 target are masters of the same bus: remote reads only work with a crossbar
  interconnect, the default of `acorn_soc2soc.py`.
- `test_bench`: the scenario tests report `ok` and `test_scenario2_crc` reports `expected failure`
  (known issue with `--with-crc`, see [6](#6-optional-line-rate-and-crc)). The measured bandwidth is
  printed for each scenario (see [Reference figures](#reference-figures)).

## 2. Build and load

### 2.1 Build

One build for every board and every scenario:

```sh
./acorn_soc2soc.py --build
```

Output goes to `build/sqrl_acorn/`. The defaults are `--sfp0=initiator --sfp1=target`, a crossbar
bus interconnect and the bandwidth bench.

- **Pass:** the build finishes, `build/sqrl_acorn/gateware/sqrl_acorn.bit` exists, and
  `build/sqrl_acorn/gateware/sqrl_acorn_timing.rpt` says "All user specified timing constraints are
  met".
- **If the CPU/BIOS build fails:** rebuild without a CPU by adding
  `--cpu-type=None --uart-name=uartbone`. All tests below still work, since they run from the host.
- **Polarity:** if step 4.1 finds that a board needs a non-default RX polarity, add the option it
  prints (e.g. `--sfp1-rx-polarity=0`) and rebuild.

### 2.2 Load or flash

The board's FTDI chip has no USB serial number, so with several boards connected each board is
selected by the **host USB port** it is plugged into (`--usb-port`, the name of the device in
`/sys/bus/usb/devices`). To find it, list the FTDI devices:

```sh
for d in /sys/bus/usb/devices/*; do [ "$(cat $d/idProduct 2>/dev/null)" = 6010 ] && echo "$(basename $d)"; done
```

Name the boards once and for all: board **A** is the one on the first port (e.g. `1-3`), board **B**
the one on the second (e.g. `1-5`). Keep each board on its port.

```sh
./acorn_soc2soc.py --load --usb-port=1-3   # Board A
./acorn_soc2soc.py --load --usb-port=1-5   # Board B
```

`--load` writes the FPGA's SRAM (lost at power-off). Use `--flash` instead to store the design in
the SPI flash once: since the gateware never changes between scenarios, the boards are then ready at
every power-up. With a single board connected, `--usb-port` can be omitted.

**Pass:** on each board, LED0 blinks (sys heartbeat) and LED3 is on (GTP QPLL locked). LED1 and LED2
(SFP0 and SFP1 links ready) are on when the cables are connected, possibly only after step 4.1.

## 3. Host setup

Start one `litex_server` per board, **board A on port 1234 and board B on port 1235** (the defaults
of `test_soc2soc.py`). Use the stable UART names of `/dev/serial/by-path`, which only depend on the
host USB port; the UART is interface `1.1` of the FTDI chip:

```sh
ls -l /dev/serial/by-path/
litex_server --uart --uart-port=/dev/serial/by-path/pci-0000:00:14.0-usb-0:3:1.1-port0 --bind-port=1234   # Board A
litex_server --uart --uart-port=/dev/serial/by-path/pci-0000:00:14.0-usb-0:5:1.1-port0 --bind-port=1235   # Board B
```

Keep them running and use another terminal for the tests. `test_soc2soc.py` uses
`build/sqrl_acorn/csr.csv` for all boards. Select the boards with `--boards=A`, `--boards=B` or
`--boards=AB` (default `A`). For readability:

```sh
T="./test_soc2soc.py --boards=AB"   # Or --boards=A with a single board.
$T ident
```

**Pass:** each board prints `LiteX SoC2SoC over SerDes on Acorn Baseboard Mini (SFP0: initiator / SFP1: target) ...`.

## 4. Scenario 1: SFP0 ⇄ SFP1 on each board

**Setup:** on each board, one DAC cable between its SFP0 and its SFP1. With two boards, both run
scenario 1 at the same time and every test below covers both.

The steps below can be run one by one, which is useful for a first bring-up. The `run` command does
them all in sequence (4.1 to 4.6 and a final status), checks each pass criterion, prints a summary
and can write the results report:

```sh
$T run --duration=300 --report=docs/results/<date>-scenario1.md
```

**Pass:** the summary ends with `=> PASS (scenario 1 (board A[, B]))`. The command returns a non-zero
exit code on failure.

### 4.1 Polarity

```sh
$T autopolarity
```

**Pass:** `RX OK with rx_polarity=X` for every SFP, then `link ready: 1`. The RX errors and link
drops counters are then cleared, since changing polarity causes errors.

If a polarity differs from the default (SFP0 RX=1, SFP1 RX=1), note it and rebuild with the
printed option (see 2.1). Polarities are properties of the board, so they also apply in scenarios 2
and 3.

### 4.2 Wiring

```sh
$T wiring
```

The TX of each SFP is silenced in turn (GTP TX inhibit, no reset) to find which SFP stops receiving.
`prbs`, `remote` and `bandwidth` run the same detection first.

**Pass:** `cable: A.sfp0 <-> A.sfp1 (scenario 1 on board A)` (and the same for B), then
`=> scenario 1 on board(s) A[, B]`.

### 4.3 Status

```sh
$T status
```

**Pass**, for every SFP:

| Field | Expected |
|-------|----------|
| GTP TX ready, GTP RX ready | 1 |
| TX/RX clk | ≈ 125 MHz (line rate / 20; 2.5 Gbps by default) |
| RX OK, Remote OK, Link ready | 1 |
| RX errors, Link drops, RX overflow, SerWB overflows | 0 |

Run `status` again after a minute: the error and link drop counters must not increase.

### 4.4 PRBS / bit error rate

```sh
$T prbs --duration=300
```

This sends a PRBS31 pattern in both directions of every cable and counts bit errors. While it runs
the links are down; they come back up at the end of the test, and the RX errors and link drops
counters (which count the PRBS pattern as errors) are cleared.

**Pass:** 0 errors in every direction. After 300 s at 2.5 Gbps, 0 errors means a BER below 1.3e-12.

### 4.5 Remote access

```sh
$T remote
```

For each initiator → target cable: reads the target board's identifier through the cable, writes
and reads back 256 random words in its mailbox, then checks the mailbox directly on the target board.

**Pass:** `remote identifier: ... (OK)`, `remote mailbox write/read of 256 words: 0 errors` and
`direct check on board X: 0 errors`, for every cable.

### 4.6 Bandwidth

```sh
$T bandwidth
```

The bench of each board (a Wishbone traffic generator in the FPGA, see `soc2soc/bench.py`) performs
4M back-to-back 32-bit writes, then 4M reads with data check, one access in flight at a time:
first on its local mailbox (reference without link), then on the remote mailbox through each cable.
With two boards, the cables are then measured at the same time.

**Pass:** 0 errors on every run, and figures close to the [reference figures](#reference-figures).

### 4.7 Robustness (optional)

1. Unplug a DAC cable. Its LEDs go off. In `status`, `Link ready` is 0.
2. Plug the cable back in. The LEDs come back on and `Link drops` has increased.
3. `remote` passes again.

## 5. Scenarios 2 and 3: between boards

**Setup:** boards A and B, with one or two DAC cables between them, each joining an SFP0 to an SFP1
of the other board. No rebuild or reload: from scenario 1 on both boards, move the SFP1 end of each
cable to the other board.

| Scenario | Cables | Access |
|----------|--------|--------|
| 2 | A.SFP0 ⇄ B.SFP1 | A accesses B |
| 3 | A.SFP0 ⇄ B.SFP1 and B.SFP0 ⇄ A.SFP1 | each board accesses the other, both at the same time |

Both scenarios use the same test routine, which detects the cables and tests what is connected
(SFPs without a cable are reported as `not connected` and skipped):

```sh
./test_soc2soc.py --boards=AB run --duration=300 --report=docs/results/<date>-scenarioN.md
```

**Pass:** the summary ends with `=> PASS (scenario 2)` or `=> PASS (scenario 3)`, with:

| Step | Pass criterion |
|------|----------------|
| Wiring | Scenario 2: `A.sfp0 <-> B.sfp1`, A.sfp1 and B.sfp0 not connected. Scenario 3: also `A.sfp1 <-> B.sfp0`. |
| Status | Criteria of 4.3 for every connected SFP. |
| PRBS | 0 errors on every direction (2 in scenario 2, 4 in scenario 3). |
| Remote | Scenario 2: `A.sfp0->B.sfp1`. Scenario 3: also `B.sfp0->A.sfp1`. Identifier OK, mailbox and direct check on the other board 0 errors. |
| Bandwidth | 0 errors. In scenario 3, both paths are also measured at the same time: each keeps its bandwidth. |
| Final status | Counters still 0. |

The two boards run on separate oscillators, so in `status` the RX clock of an SFP differs slightly
from its TX clock. That is expected: the difference is absorbed by the clock-domain-crossing FIFOs.
Also run the robustness check (4.7) on these links.

The individual commands (`wiring`, `status`, `prbs`, `remote`, `bandwidth`) can also be run one by
one, as in scenario 1.

## 6. Optional: line rate and CRC

Repeat steps 4.3 to 4.6 (or `run`) with other settings. All boards must be built with the same options, and
`prbs`/`bandwidth` need the matching `--linerate` so the BER and link capacity are computed
correctly.

| Build options | TX/RX clk | `test_soc2soc.py` option |
|---------------|-----------|--------------------------|
| `--linerate=1.25e9` | 62.5 MHz | `--linerate=1.25e9` |
| `--refclk-freq=156.25e6 --linerate=3.125e9` | 156.25 MHz | `--linerate=3.125e9` |
| `--linerate=5e9` | 250 MHz, check timing | `--linerate=5e9` |
| `--with-crc` | unchanged | – |

At 5 Gbps the GTP reference clock comes from the fabric PLL, so it is more jittery. A non-zero BER
at that rate is a limitation of the board's clocking, not necessarily a bug.

**Known issue with `--with-crc`:** in simulation (`test_scenario2_crc`), back-to-back remote writes
complete but about half of the following reads return wrong data. Do not use `--with-crc` for
bandwidth measurements until this is fixed.

## Reference figures

Scenario 1 on boards A and B at the same time, 2.5 Gbps, sys clock 100 MHz, no CRC. The link layer
payload capacity is 248 MB/s per direction (2 bytes per 125 MHz cycle, one IDLE every 64 words).

| Path | Write | Read | Access latency (read) |
|------|-------|------|-----------------------|
| Local mailbox (no link) | 200 MB/s | 200 MB/s | 20 ns |
| Through one cable, hardware | 123 MB/s | 4.9 MB/s | 820 ns |
| Through one cable, simulation | 124 MB/s | 10.7 MB/s | ≈ 400 ns |
| Two cables at the same time, hardware | 246 MB/s total | 9.8 MB/s total | 820 ns |

- **Writes** are posted by the SerWB initiator: back-to-back writes use half of the link capacity.
- **Reads** wait for the response, one at a time: the bandwidth is 4 bytes per round trip. The
  hardware round trip is longer than in simulation because of the GTP latency (TX/RX buffers, 8b/10b,
  serialization), which the simulation does not model.
- Each cable is independent: two cables at the same time give twice the bandwidth.

## Troubleshooting

| Symptom | Likely cause / action |
|---------|-----------------------|
| LED3 off (QPLL not locked) | The refclk/line rate combination is invalid: check the `GTPQuadPLL` configuration printed during the build. GTP TX/RX ready then stay at 0. |
| `GTP TX ready` or `GTP RX ready` is 0 | QPLL not locked (see above), or the GTP is held in reset (`sfpN_serdes_tx_enable` / `rx_enable` CSRs at 0). |
| `autopolarity` fails with both polarities | No valid signal received. Check that the cable is fully inserted and that the remote end is loaded and built with the same line rate. Retry at `--linerate=1.25e9`. |
| `wiring`: `not connected` | No cable, or no signal in either direction: check the cable, then run `autopolarity`. |
| `wiring`: `one-way` | Only one direction receives: check the RX polarity and `status` of the SFP that does not receive. |
| `wiring`: `both initiators` / `both targets` | The cable joins two SFP0 or two SFP1: move one end to an SFP1 / SFP0. |
| `RX OK` is 1 but `Remote OK` is 0 | This side receives, but the other direction is broken: check the remote end's RX (its polarity and its `status`). |
| `RX errors` or `Link drops` increase | Marginal signal quality. Run `prbs`, try a lower line rate or another cable, or tune the TX drive (`sfpN_serdes_tx_diffctrl`, `sfpN_serdes_tx_postcursor` CSRs). |
| PRBS errors in one direction only | Check that direction's cable end and its TX/RX electrical settings. |
| `remote`: "link not ready, skipping" | The link is down: fix `status` first. |
| `remote`: reads return `0xffffffff` but writes work (scenario 1) | Bus deadlock: the gateware was built with `--bus-interconnect=shared`. Rebuild with the default (`crossbar`). |
| `remote`: wrong data or a bus error | Check `SerWB overflows` / `RX errors` in `status`. |
| `litex_server` gets no response | Wrong UART (use `/dev/serial/by-path`, interface `1.1`), or the board is not loaded. Check that LED0 blinks. |
| `--usb-port`: `No USB device on port` | The board is not on that host port: list the ports as in 2.2. |
| Simulation fails with `AttributeError: 'NoneType' object has no attribute 'eq'` in your own designs | Stale GitHub Migen: install the official one (see [Migen version](../README.md#migen-version)). |

When reporting a problem, include the output of `wiring` and `status` and the Vivado timing summary.

## Results template

Copy this into an issue or pull request comment to record a test campaign.

```markdown
### SoC2SoC test results

- Date / commit:
- Boards (USB port, Acorn variant): A: , B:
- DAC cables (vendor, length):
- Vivado version / LiteX commit:
- Polarities used (SFP0 TX/RX, SFP1 TX/RX):

| Step | Scenario | Line rate | Result | Notes |
|------|----------|-----------|--------|-------|
| 1    | Simulation | – | | |
| 2.1  | Build / timing | 2.5G | | |
| 4.1  | 1 autopolarity | 2.5G | | |
| 4.2  | 1 wiring | 2.5G | | |
| 4.3  | 1 status | 2.5G | | |
| 4.4  | 1 PRBS31 300s (errors / BER) | 2.5G | | |
| 4.5  | 1 remote | 2.5G | | |
| 4.6  | 1 bandwidth (write / read MB/s) | 2.5G | | |
| 4.7  | 1 unplug/replug | 2.5G | | |
| 5    | 2 run (wiring / status / PRBS / remote / bandwidth) | 2.5G | | |
| 5    | 3 run (wiring / status / PRBS / remote / bandwidth) | 2.5G | | |
| 6    | Line rate / CRC variants | | | |
```
