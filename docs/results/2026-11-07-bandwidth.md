### SoC2SoC bandwidth campaign (scenario 2, A.SFP0 ⇄ B.SFP1)

- Date: 2026-11-07
- Boards: A (host USB port 1-3) and B (host USB port 1-5), CLE-215+, one passive DAC cable
- Vivado 2023.2.2, same gateware on both boards for each variant
- Gateware: link layer with flow control (pause requests in IDLEs, 256-word RX buffer),
  bench with pipelined checks
- Measurement: `test_soc2soc.py --boards=AB bandwidth`, 4M x 32-bit accesses per run, one access in
  flight at a time, data checked (0 errors in every run)

#### Results

| Variant | Build options | Timing (WNS) | PRBS31 | Write | Read | Read round trip |
|---------|---------------|--------------|--------|-------|------|-----------------|
| Baseline (before) | defaults (2.5 Gbps, 100 MHz, burst 4), no flow control | +0.767 ns | 0 errors, 60 s | 123.1 MB/s | 4.88 MB/s | 820 ns |
| A | `--burst-depth=64` | +0.897 ns | 0 errors, 10 s | 192.5 MB/s | 4.64 MB/s | 870 ns |
| – | `--burst-depth=64 --sys-clk-freq=150e6` | **-0.637 ns (not met)** | – | – | – | – |
| B | `--burst-depth=64 --sys-clk-freq=125e6` | +0.198 ns | 0 errors, 10 s | 233.5 MB/s | 4.91 MB/s | 816 ns |
| C | `--burst-depth=64 --sys-clk-freq=125e6 --linerate=5e9` | +0.084 ns | 0 errors, 60 s (BER ≤ 3.3e-12) | **240.6 MB/s** | **7.92 MB/s** | 512 ns |

Local mailbox (no link): 200 MB/s at 100 MHz, 250 MB/s at 125 MHz (2 sys cycles per access).
Status after each run: RX errors, link drops, RX overflow and SerWB overflows at 0 on the cable ends.

#### Analysis

- **Writes** are posted and coalesced by SerWB (up to `burst_depth` words per packet, 4 words of
  overhead per packet). The limits are:
  - packet efficiency: `burst_depth / (burst_depth + 4)` of the link capacity (248 MB/s at 2.5 Gbps,
    496 MB/s at 5 Gbps): 50 % with burst 4 (baseline, 124 MB/s), 94 % with burst 64 (233 MB/s,
    variant B: link-limited);
  - sys side: 2 sys cycles per access (bus + SerWB initiator): 200 MB/s at 100 MHz (variant A),
    250 MB/s at 125 MHz (variant C: sys-limited).
- **Reads** are blocking, one word per round trip: bandwidth = 4 bytes / round trip. The round trip
  is mostly fixed latency (GTP TX/RX pipelines, CDC FIFOs, SerWB buffering); 5 Gbps halves the GTP
  part (816 → 512 ns).
- **150 MHz** fails timing: the SerWB target (address adder) and initiator (acknowledge) paths go
  combinationally through the SoC crossbar. 125 MHz is the highest sys clock tested.
- **5 Gbps** works with 0 PRBS errors over 60 s even with the fabric-generated GTP reference clock.

#### Simulation (`test/test_bench.py`, transceivers as direct connections, scenario 2)

| Line rate | sys clock | burst 4 | burst 16 | burst 64 | Read |
|-----------|-----------|---------|----------|----------|------|
| 2.5 Gbps | 100 MHz | 123.2 MB/s | 173.7 MB/s | 195.7 MB/s | 10.0 MB/s |
| 2.5 Gbps | 150 MHz | 123.6 MB/s | 199.6 MB/s | 241.9 MB/s | 11.8 MB/s |
| 5 Gbps | 100 MHz | 123.2 MB/s | 173.7 MB/s | 195.7 MB/s | 11.8 MB/s |
| 5 Gbps | 150 MHz | 184.9 MB/s | 260.6 MB/s | 293.5 MB/s | 16.2 MB/s |

#### Flow control

Before this campaign, the link layer had no flow control: a receiver slower than the link (remote
bus, or SerWB CRC checking) silently lost words. This was the cause of the `--with-crc` read errors
seen in simulation. With flow control, `test_scenario2_crc` and the new `test_flow_control` (receiver
4x slower than the link, 2000 words, no loss) pass, and burst 64 / 5 Gbps run without overflow.

#### Read prefetch

Reads are blocking, one word per round trip, because SERWBMMAPSlave requests one word per Wishbone
read. `soc2soc/serwb_prefetch.py` requests the block from the read address to the end of its
`burst_depth`-aligned block (64 words) and serves the next sequential reads from it as the words
arrive (opt-in per window, `sfpN_window_prefetch` CSR).

Hardware, defaults (2.5 Gbps, 100 MHz, burst 64), scenario 3 (A.SFP0 ⇄ B.SFP1 and B.SFP0 ⇄ A.SFP1),
report in [2026-11-07-scenario3-prefetch.md](2026-11-07-scenario3-prefetch.md):

| Path | Write | Read | Read + prefetch |
|------|-------|------|-----------------|
| A.sfp0 -> B.sfp1 | 192.48 MB/s | 4.65 MB/s | 81.68 MB/s |
| B.sfp0 -> A.sfp1 | 192.48 MB/s | 4.65 MB/s | 81.57 MB/s |
| Both at the same time (aggregate) | 384.97 MB/s | 9.30 MB/s | 163.24 MB/s |

Simulation (scenario 2, 2.5 Gbps, 100 MHz, burst 64): read 9.9 MB/s, read + prefetch 95.5 MB/s.
Each block costs one round trip plus its transfer (64 words); requesting the next block before the
current one is consumed (look-ahead) would overlap them.
