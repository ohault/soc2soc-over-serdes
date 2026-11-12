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

## Experimental bonded packet transport

This branch also develops a separate, board- and SoC-agnostic packet transport
that bonds the two physical SFP/DAC lanes into one logical full-duplex link.
It is **not yet wired into `acorn_soc2soc.py`**, does not replace the existing
SerWB implementation, and must be treated as experimental until its RTL regressions pass and hardware validation is completed.

The generic RTL includes an autonomous two-lane node, HELLO/READY session
negotiation, cumulative byte/packet credits, DATA/CONTROL framing, packet
reordering, raw-byte frame reconstruction, a generic 8b/10b byte adapter and a
parallel 8b/10b wrapper (`bonded_two_lane_phy_word_node`) with independent TX
and recovered-RX clock domains. It discovers remote lane IDs, so crossed SFP
cables are supported without changing the logical transport. The workflow now
contains end-to-end two-node regressions with simultaneous bidirectional
traffic, variable-length packets, both lanes, application RX backpressure,
crossed-cable lane mapping and malformed-PHY-symbol fault propagation. The
latest explicitly confirmed GitHub Actions success predates these final
integration changes; rerunning CI on the current branch is a release gate.
Board-specific SERDES primitives and clocks remain outside the bonding core.

- [Project roadmap](docs/project-roadmap.md)
- [RTL control transport](docs/rtl-control-transport.md)
- [Physical byte-stream contract](docs/physical-byte-stream-interface.md)
- [SERDES adapter research and throughput limits](docs/serdes-adapter-research.md)
- [Parallel lane-word interface proposal](docs/parallel-lane-word-interface.md)
- [Acorn CLE-215+ GTP adapter plan](docs/acorn-gtp-adapter.md)
- [Dynamic lane mapping and crossed-cable behavior](docs/dynamic-lane-mapping.md)
- [RTL session epoch v1 proposal](docs/session-epoch-v1.md)

The conservative one-byte-per-PHY-word mode is suitable for initial bring-up.
The multi-byte PHY adapter is not yet safe for sustained full-rate traffic:
the wire framing and final logical RX application interface are still
byte-wide and must be widened end to end. No hardware
validation has been performed yet.

## Scenarios

Every board runs the same gateware: **SFP0 is the initiator and SFP1 the target**. Every DAC cable
joins an SFP0 to an SFP1, so going from one scenario to another only means moving cables (no
rebuild, no reload), and `test_soc2soc.py` detects the cabling by itself.

| # | Cables | Access |
|---|--------|--------|
| 1 | A.SFP0 ⇄ A.SFP1 (and/or B.SFP0 ⇄ B.SFP1 at the same time) | Each board accesses its own bus |
| 2 | A.SFP0 ⇄ B.SFP1 | A accesses B |
| 3 | A.SFP0 ⇄ B.SFP1 and B.SFP0 ⇄ A.SFP1 | Each board accesses the other |

- **Scenario 1** is a loopback. The SoC reaches its own bus through the cable: SFP0 sends, SFP1
  executes. This validates both GTP channels, the cable and the protocol on a single board.
- **Scenario 2** lets board A access board B.
- **Scenario 3** has two independent links, one per direction. Each board accesses the other
  through its SFP0 initiator window, both at the same time.

The roles can still be changed with `--sfp0` / `--sfp1` (`none`, `initiator` or `target`).

## Layout

| File | Description |
|------|-------------|
| `acorn_soc2soc.py` | Existing LiteX SerWB target for the Acorn Baseboard Mini: CRG, GTP QPLL, SFP links, mailbox and LEDs. |
| `acorn_bonded.py` | Separate experimental bonded-link target with bidirectional packet-pattern testing; leaves the SerWB target unchanged. |
| `soc2soc/link.py` | SerDes link layer: 32-bit stream over a 2-byte 8b/10b transceiver, link-up handshake, error detection. Can be used as a SerWB PHY. |
| `soc2soc/serdes_link.py` | `GTPSoCLink`: LiteICLink GTP + link layer + SerWB core + remote window + optional stream port. |
| `soc2soc/bonded_acorn.py` | Prototype Acorn two-GTP binding for the board-neutral bonded packet node; separate from the existing SerWB target. |
| `soc2soc/bonded_tester.py` | Bidirectional fixed-size packet generator/checker for link bring-up. |
| `soc2soc/stream.py` | `SerWBStreamPort`: bidirectional 32-bit stream with credit-based flow control, next to register access. `StreamTester`: counter generator/checker. |
| `soc2soc/serwb_prefetch.py` | SerWB native slave with read prefetch (same protocol, used on the initiator side). |
| `soc2soc/bench.py` | `WishboneBench`: Wishbone traffic generator to measure bandwidth and latency from the FPGA. |
| `test_soc2soc.py` | Host utility (through `litex_server`): `ident`, `status`, `autopolarity`, `wiring`, `prbs`, `remote`, `bandwidth`, `stream`, `run` (full sequence with report). |
| `test/test_link.py` | Simulation: two link layers back to back with SerWB on top (byte misalignment, CRC and error recovery cases, single-SoC bus deadlock). |
| `test/test_bench.py` | Simulation: bandwidth/latency of each scenario (one and two DAC cables). |
| `test/test_stream.py` | Simulation: stream port with a slow consumer, and register access while a stream consumer is stalled. |
| `test/test_programmer.py` | Board selection by host USB port: FTDI chip / programming cable detection. |
| `board_lock.py` | Board locks for a shared bench: one lock file per board (host USB port), checked by `acorn_soc2soc.py --load`. Rules in [AGENTS.md](AGENTS.md). |
| `test/test_board_lock.py` | Board lock owner checks and all-or-nothing acquire. |

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
./acorn_soc2soc.py --build                    # One build for all boards and scenarios.
./acorn_soc2soc.py --load --usb-port=1-3      # Board A (or --flash, once).
./acorn_soc2soc.py --load --usb-port=1-5      # Board B.
```

The experimental bonded transport has a separate target and does not modify
the existing SerWB target. Build matching images with complementary peer IDs
and the same initial session seed:

```sh
# Board A
./acorn_bonded.py --build --peer-id=1 --expected-peer-id=2 --session-id=1

# Board B
./acorn_bonded.py --build --peer-id=2 --expected-peer-id=1 --session-id=1
```

Load each image onto its corresponding board with the same `--load` and
`--usb-port` options. Connect both SFP DAC paths between the boards. The
bonded target starts a bidirectional 64-byte packet pattern test after session
negotiation; see [Acorn bonded adapter](docs/acorn-gtp-adapter.md).


The board's FTDI chip has no USB serial number: with several boards connected, `--usb-port` selects
a board by the host USB port it is plugged into (see `/sys/bus/usb/devices`, and
[docs/test-procedure.md](docs/test-procedure.md#22-load-or-flash)), and detects that board's FTDI
chip (FT2232, FT4232 or FT232H) to pick the programming cable. It can be omitted with a single
board.

Useful options:

- `--linerate`: the default is `2.5e9`. With the default 125 MHz reference, `1.25e9` and `5e9` also
  work. `--refclk-freq=156.25e6 --linerate=3.125e9` is another valid combination. Both ends of a
  link must use the same line rate.
- `--with-crc`: adds a CRC to SerWB packets; corrupted packets are dropped and counted. Set it on
  both ends of a link.
- `--with-stream`: adds a stream port with flow control on each link, next to register access, with
  a stream tester connected to it. See [Stream port](#stream-port). Set it on all boards.
- `--burst-depth`: the default is `64`. Consecutive writes coalesced in one SerWB packet. Set the
  same value on both ends of a link.
- `--sys-clk-freq`: the default is `100e6`. `125e6` gives more bandwidth (see Throughput);
  `150e6` does not meet timing.
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
# One litex_server per board: board A on port 1234, board B on port 1235 (stable UART names).
litex_server --uart --uart-port=/dev/serial/by-path/<board A>-usb-0:3:1.1-port0 --bind-port=1234
litex_server --uart --uart-port=/dev/serial/by-path/<board B>-usb-0:5:1.1-port0 --bind-port=1235

T="./test_soc2soc.py --boards=AB"   # Or --boards=A / --boards=B.
$T run --report=results.md          # Everything below in sequence, with pass/fail summary and report.

$T autopolarity  # Fix RX polarities if needed.
$T wiring        # Detect the cables and the scenario.
$T status        # GTP/link status, clocks, counters.
$T prbs          # PRBS31 BER test, both directions of every cable.
$T remote        # Remote ident + mailbox through each cable, direct check on the target board.
$T bandwidth     # Bandwidth/latency through each cable, measured from the FPGA.
```

`wiring` silences the TX of each SFP in turn and sees which SFP stops receiving. `prbs`, `remote`
and `bandwidth` run it first, so they work with any cabling.

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

Sequential reads through the window can be accelerated with **read prefetch**: set the
`sfpN_window_prefetch` CSR to 1 and blocks of up to `--burst-depth` words are read ahead on the
remote bus, and the next block is requested while the current one is consumed (4.6 → 125 MB/s).
Read-ahead never crosses a 4 KB boundary, so it does not go past the end of a 4 KB-aligned memory. Only enable it when the page holds memory: prefetched words are really
read on the remote side, so registers with read side effects (FIFOs, clear-on-read) would be
affected. The block is discarded on any write or non-sequential read. It is off by default.

Accesses fail with a bus error while the link is down, so they never stall the bus. In loopback
(scenario 1), don't map the window onto the window itself: that access would loop forever.

### Stream port

Register access (READ/WRITE through the window) suits control: configuring the remote SoC and
reading its status. For data, `--with-stream` adds a **stream port** on each link:

```
  SoC A  sink   ─▶ ═══ SerWB port 1 ═══ ─▶ source  SoC B
         source ◀─ ═══ SerWB port 1 ═══ ◀─ sink
                     (port 0: register access, unchanged)
```

- **Bidirectional and symmetric.** Each side has a `sink` (data to the remote) and a `source`
  (data from the remote): 32-bit words with `last` for frame boundaries, in the sys clock domain.
  The stream port is independent of the initiator/target role, and follows the cable: A.SFP0 ⇄
  B.SFP1 streams both ways.
- **Credit-based flow control.** The receiver advertises the free space in its RX buffer (512
  words), and the sender only sends what fits. A slow consumer slows the sender down, with no data
  loss. A stopped consumer stops the stream but **never blocks register access**, because received
  stream data never stalls the link.
- **Packets.** Data is sent in packets of up to 64 words, plus a header word and 2 words of SerWB
  framing (67 words), and the receiver returns a 3-word credit packet every 64 words on the other
  direction of the cable. Measured at 2.5 Gbps (248 MB/s link capacity): **237 MB/s** with one
  direction streaming (64/67), **227 MB/s per direction** with both directions of a cable streaming,
  since each direction then also carries the other's credits (64/70). A packet is sent as soon as it
  is full, when `last` is seen, or after 64 idle cycles.
- **Link loss.** Data not yet sent is dropped, and a frame in flight can be truncated. The sink is
  stalled until the link is back. Data already received stays in the RX buffer.

In the Acorn target, the stream port is connected to a `StreamTester`: a counter generator plus a
checker with a configurable consumer speed. `test_soc2soc.py stream` (also part of `run`) uses it to
measure throughput and check integrity. To connect your own logic instead, use `link.stream.sink`
and `link.stream.source` of the `GTPSoCLink` (`soc.links[n]`) and build without the tester
(`with_stream_tester=False`).

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
- Flow control: received words go to a 256-word buffer. When it fills up (slow remote bus, CRC
  checking), a pause request is sent in an IDLE and the remote stops sending data until it is
  released, so no word is lost.

**Throughput.** The link layer payload capacity is linerate × 0.8 (8b/10b) minus the IDLE overhead,
248 MB/s per direction at 2.5 Gbps. Measured on hardware with the bench (one access in flight at a
time): writes, which SerWB posts and coalesces (`--burst-depth`, default 64), reach 192 MB/s at the
default 100 MHz sys clock, 233 MB/s at `--sys-clk-freq=125e6` and 241 MB/s with `--linerate=5e9`.
Reads wait for each response and reach 4.6 to 7.9 MB/s (one word per round trip of 500 to 870 ns),
or 125 MB/s with read prefetch. Each cable is independent. See the [reference figures](docs/test-procedure.md#reference-figures).

**SFP sideband.** The SFP sideband is not used: the SFP I2C bus (`sfp_i2c`) is in the platform for
reading DAC/module EEPROMs, and passive DACs need no TX_DISABLE control.

## Simulation

```sh
python3 -m unittest test.test_link -v    # Link layer + SerWB.
python3 -m unittest test.test_bench -v   # Bandwidth/latency of each scenario (one and two DAC cables).
python3 -m unittest test.test_stream -v  # Stream port (credit-based flow control).
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
