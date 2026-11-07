### SoC2SoC test results: scenario 3

- Date: 2026-11-07 17:45
- Boards: A (litex_server port 1234), B (litex_server port 1235)
- Gateware: A: LiteX SoC2SoC over SerDes on Acorn Baseboard Mini (SFP0: initiator / SFP1: target) 2026-11-07 17:36:41, B: LiteX SoC2SoC over SerDes on Acorn Baseboard Mini (SFP0: initiator / SFP1: target) 2026-11-07 17:36:41
- Cabling: A.sfp0 <-> B.sfp1; A.sfp1 <-> B.sfp0
- Polarities: A.sfp0 TX/RX 0/1, A.sfp1 TX/RX 0/1, B.sfp0 TX/RX 0/1, B.sfp1 TX/RX 0/1
- Line rate: 2.500 Gbps

| Step | Result | Notes |
|------|--------|-------|
| Ident | PASS | A, B |
| Autopolarity | PASS | connected SFPs OK with current polarities |
| Wiring | PASS | scenario 3; A.sfp0 <-> B.sfp1; A.sfp1 <-> B.sfp0 |
| Status | PASS | A.sfp0: clk 125.013/125.015MHz; B.sfp1: clk 125.003/125.001MHz; A.sfp1: clk 125.012/125.013MHz; B.sfp0: clk 125.021/125.019MHz |
| PRBS (prbs31, 60s) | PASS | A.sfp0->B.sfp1: 0 errors, BER<=6.67e-12; B.sfp1->A.sfp0: 0 errors, BER<=6.67e-12; A.sfp1->B.sfp0: 0 errors, BER<=6.67e-12; B.sfp0->A.sfp1: 0 errors, BER<=6.67e-12 |
| Remote | PASS | A.sfp0->B.sfp1: ident OK, 0 errors, direct 0 errors; B.sfp0->A.sfp1: ident OK, 0 errors, direct 0 errors |
| Bandwidth | PASS | A.sfp0->B.sfp1: write 192.5, read 4.69, read+prefetch 124.6 MB/s; B.sfp0->A.sfp1: write 192.5, read 4.65, read+prefetch 124.6 MB/s |
| Final status | PASS | counters still 0 |

#### Bandwidth (4194304 x 32-bit accesses per run, one in flight at a time)

Link layer payload capacity: 248.1 MB/s per direction.

| Path | Write | Read | Read + prefetch | Access avg / max (write) | Access avg / max (read) | Errors |
|------|-------|------|-----------------|--------------------------|-------------------------|--------|
| A local mailbox | 200.00 MB/s | 200.00 MB/s | – | 20.0 / 30 ns | 20.0 / 20 ns | 0 |
| B local mailbox | 200.00 MB/s | 200.00 MB/s | – | 20.0 / 30 ns | 20.0 / 20 ns | 0 |
| A.sfp0->B.sfp1 | 192.48 MB/s | 4.69 MB/s | 124.64 MB/s | 20.8 / 700 ns | 852.8 / 860 ns | 0 |
| B.sfp0->A.sfp1 | 192.48 MB/s | 4.65 MB/s | 124.58 MB/s | 20.8 / 700 ns | 860.0 / 870 ns | 0 |
| A.sfp0->B.sfp1 (all paths at once) | 192.48 MB/s | 4.69 MB/s | 124.64 MB/s | 20.8 / 700 ns | 852.8 / 860 ns | 0 |
| B.sfp0->A.sfp1 (all paths at once) | 192.48 MB/s | 4.65 MB/s | 124.58 MB/s | 20.8 / 700 ns | 860.0 / 870 ns | 0 |
| Aggregate (all paths at once) | 384.97 MB/s | 9.34 MB/s | 249.22 MB/s | | | |
