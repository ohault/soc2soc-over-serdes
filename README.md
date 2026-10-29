# soc2soc-over-serdes

SoC-to-SoC interconnect over FPGA transceivers with [LiteX](https://github.com/enjoy-digital/litex),
targeting the **LiteX Acorn Baseboard Mini** fitted with a **SQRL Acorn CLE-215+** (Artix-7
XC7A200T, GTP transceivers). The SFP cages are linked with **passive DAC cables**.

Each SFP link carries [LiteICLink](https://github.com/enjoy-digital/liteiclink)'s SerWB
memory-mapped protocol. One SoC (the *initiator*) reads and writes the bus of the other SoC (the
*target*) through a window in its own memory map: CSRs, RAM, the mailbox, and so on.

```
        Initiator SoC                                                  Target SoC
  CPU/Host ─▶ RemoteWindow ─▶ SerWB core                     SerWB core ─▶ SoC bus (master)
   0x8000_0000 (SFP0)             │                               ▲
   0x9000_0000 (SFP1)       SerDes link layer               SerDes link layer
                                  │                               │
                             GTP (8b/10b) ═══ SFP ══ DAC ══ SFP ═══ GTP (8b/10b)
```

## Scenarios

Each SFP port has a role, set with `--sfp0` / `--sfp1`: `none`, `initiator` or `target`.

| # | Setup | Board A | Board B |
|---|-------|---------|---------|
| 1 | Single board, SFP0 ⇄ DAC ⇄ SFP1 | `--sfp0=initiator --sfp1=target` | – |
| 2 | Two boards, SFP0 ⇄ DAC ⇄ SFP0 | `--sfp0=initiator` | `--sfp0=target` |
| 3 | Two boards, SFP0 ⇄ DAC0 ⇄ SFP0 and SFP1 ⇄ DAC1 ⇄ SFP1 | `--sfp0=initiator --sfp1=target` | `--sfp0=target --sfp1=initiator` |

- **Scenario 1** is a loopback. The SoC reaches its own bus through the cable: SFP0 sends, SFP1
  executes. This validates both GTP channels, the cable and the protocol on a single board.
- **Scenario 2** lets board A access board B.
- **Scenario 3** has two independent links, one per direction. Each board can access the other
  board through its SFP initiator window.

## Layout

| File | Description |
|------|-------------|
| `acorn_soc2soc.py` | LiteX target for the Acorn Baseboard Mini: CRG, GTP QPLL, SFP links, mailbox and LEDs. |
| `soc2soc/link.py` | SerDes link layer: 32-bit stream over a 2-byte 8b/10b transceiver, link-up handshake, error detection. Can be used as a SerWB PHY. |
| `soc2soc/serdes_link.py` | `GTPSoCLink`: LiteICLink GTP + link layer + SerWB core + remote window. |
| `test_soc2soc.py` | Host utility (through `litex_server`): `ident`, `status`, `autopolarity`, `prbs`, `remote`. |
| `test/test_link.py` | Simulation: two link layers back to back with SerWB on top (byte misalignment, CRC and error recovery cases). |

## Installation

Install LiteX with the standard `litex_setup.py` flow, which includes `liteiclink`, `liteeth` and
`litex-boards`. Vivado is needed to build the bitstream.

```sh
wget https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py
python3 litex_setup.py --init --install --user --config=standard
pip3 install --user meson ninja && python3 litex_setup.py --gcc=riscv   # For the CPU/BIOS.
```

## Build and load

```sh
# Scenario 1 (single board).
./acorn_soc2soc.py --sfp0=initiator --sfp1=target --build --load

# Scenario 2.
./acorn_soc2soc.py --sfp0=initiator --output-dir=build/board_a --build --load   # Board A
./acorn_soc2soc.py --sfp0=target    --output-dir=build/board_b --build --load   # Board B

# Scenario 3.
./acorn_soc2soc.py --sfp0=initiator --sfp1=target    --output-dir=build/board_a --build --load
./acorn_soc2soc.py --sfp0=target    --sfp1=initiator --output-dir=build/board_b --build --load
```

Useful options:

- `--linerate`: the default is `2.5e9`. With the default 125 MHz reference, `1.25e9` and `5e9` also
  work. `--refclk-freq=156.25e6 --linerate=3.125e9` is another valid combination. Both ends of a
  link must use the same line rate.
- `--with-crc`: adds a CRC to SerWB packets; corrupted packets are dropped and counted. Set it on
  both ends of a link.
- `--sfpN-tx-polarity` / `--sfpN-rx-polarity`: the default polarity of each GTP. See
  [Polarity](#polarity).
- `--cpu-type`: the default is a VexRiscv with its BIOS. Use `--cpu-type=None --uart-name=uartbone`
  for a host-only SoC.
- `--uart-name`: the default is `crossover+uartbone`. One USB/UART cable then gives both
  `litex_server` access (UARTBone) and the BIOS console (`litex_term crossover`).
  `--with-jtagbone` adds host access over JTAG.

LEDs on the Acorn module:

| LED | Meaning |
|-----|---------|
| 0 | Sys heartbeat |
| 1 | SFP0 link ready |
| 2 | SFP1 link ready |
| 3 | GTP QPLL lock |

## Bring-up and tests

The full step-by-step procedure, with expected results for each scenario, troubleshooting and a
results template, is in [docs/test-procedure.md](docs/test-procedure.md). Quick reference:

```sh
# Single board.
litex_server --uart --uart-port=/dev/ttyUSBX
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv status        # GTP/link status, clocks, counters.
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv autopolarity  # Fix RX polarities if needed.
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv prbs          # PRBS31 BER test, both directions.
./test_soc2soc.py --csr-csv=build/sqrl_acorn/csr.csv remote        # Remote ident + mailbox through the link.

# Two boards: one litex_server per board, on different ports.
litex_server --uart --uart-port=/dev/ttyUSBX --bind-port=1234
litex_server --uart --uart-port=/dev/ttyUSBY --bind-port=1235
./test_soc2soc.py --csr-csv=build/board_a/csr.csv --port=1234 \
                  --peer-csr-csv=build/board_b/csr.csv --peer-port=1235 status   # Or autopolarity/prbs/remote.
```

The `remote` command does the following for each link where the board is the initiator:

1. It reads the remote SoC's identifier through the window.
2. It writes random data to the remote mailbox and reads it back through the link.
3. With two boards, it also checks the data directly on the remote board.

### Remote window

Each initiator SFP maps a 256 MB window of the local memory map: `0x8000_0000` for SFP0 and
`0x9000_0000` for SFP1. The window is mapped onto one 256 MB *page* of the remote 32-bit address
space:

```
remote_address = (sfpN_window_page << 28) | (local_address & 0x0fff_ffff)
```

`sfpN_window_page` is a CSR and defaults to `0xf`, the remote CSRs when a CPU is used. For example,
set the page to `0x2` to reach the remote mailbox at `0x2000_0000`. From the local CPU or BIOS:

```
mem_write 0xf000xxxx 0x2    # sfp0_window_page = 2 (see csr.csv for the address).
mem_read  0x80000000 64     # Remote mailbox.
```

Accesses fail with a bus error while the link is down, so they never stall the bus. In loopback
(scenario 1), don't map the window onto the window itself: that access would loop forever.

### Polarity

The Acorn and the baseboard swap some P/N pairs.

- **SFP0**: the defaults (TX=0, RX=1) are the values LiteX-Boards uses for 1000BASE-X on this
  board, so they are known to work.
- **SFP1**: no reference design uses it. The defaults assume the same swaps as SFP0.

Only the end-to-end inversion matters (local TX swap XOR remote RX swap), and it is fixed at the
receiver. `test_soc2soc.py autopolarity` toggles each RX polarity until valid IDLEs are received,
then prints the build option to make the result permanent, e.g. `--sfp1-rx-polarity=0`. All
polarities can also be changed at runtime through the `sfpN_tx_polarity` and `sfpN_rx_polarity`
CSRs.

## Design notes

**Clocking.** The Baseboard Mini has no MGTREFCLK routed to the SFP lanes. The GTP QPLL therefore
gets its reference from the fabric: a dedicated `S7PLL` from the 200 MHz oscillator drives
`GTGREFCLK`, as the LiteX-Boards Ethernet/SATA designs do. Both SFP channels share this QPLL; they
are in the same GTP quad. Fabric clocks are more jittery than a dedicated reference: 1.25 to
3.125 Gbps is comfortable, while 5 Gbps should be validated with `prbs` first.

**GTP datapath.** The GTP uses LiteICLink's `GTP` with a 20-bit datapath (2 × 8b/10b), TX and RX
buffers, and comma alignment on byte 0. TX runs on TXOUTCLK and RX on the recovered clock. Between
two boards, the ppm difference is absorbed by the RX → sys asynchronous FIFO, so no clock
correction is needed.

**Link layer** (`soc2soc/link.py`).

- IDLE words are a K28.5 plus a status byte that echoes the local RX state. The link is *ready* once
  both sides receive each other.
- 32-bit words are sent as two 16-bit halves, and an IDLE is inserted at least every 64 words. This
  keeps alignment and status fresh.
- Any 8b/10b or framing error drops the link immediately. The link comes back after 16 clean IDLEs,
  and SerWB is reset on each drop. Counters show RX errors, link drops and overflows.

**Throughput.** The raw payload is linerate × 0.8 (8b/10b) minus the IDLE overhead, about 2 Gbps at
2.5 Gbps. Actual SerWB throughput is lower: each transaction is a request/response over the link.

**SFP sideband.** The SFP sideband is not used: the SFP I2C bus (`sfp_i2c`) is in the platform for
reading DAC/module EEPROMs, and passive DACs need no TX_DISABLE control.

## Simulation

```sh
python3 -m unittest test.test_link -v
```

### Migen version

Use the official Migen: install it with `litex_setup.py` (it clones https://git.m-labs.hk/M-Labs/migen)
or with `pip install migen`.

Do not use the old GitHub copy, https://github.com/m-labs/migen. That repository stopped being
updated when Migen moved to git.m-labs.hk in January 2026. It still contains commit `7bf0214`
("specials: memory: add read_capable option"), which breaks the simulation of any design with a
`SyncFIFO`/`AsyncFIFO`: it fails with `AttributeError: 'NoneType' object has no attribute 'eq'`. The
official repository reverted that commit (`0efcff4`), and the GitHub copy never received the revert.

`test/test_link.py` detects that broken Migen and works around it, so the simulation runs with
either version. Hardware builds (Verilog generation) are not affected.
