# Two-lane CDC boundary

The `bonded_two_lane_cdc` module is the clock-domain boundary between two
independent physical receive lanes and a common bonding-engine clock.

## Clocking and data paths

- `lane0_clk` and `lane1_clk` are independent recovered clocks.
- Each lane writes into its own `bonded_async_fifo`.
- `bond_clk` reads both FIFOs independently.
- Lane 0 and lane 1 retain separate valid/ready/data interfaces. This block
  performs no arbitration, lane striping, packet merging, sequence handling,
  deskew, or replay.

The bonding engine is responsible for consuming the two lane streams and
reconstructing the logical transport.

## Reset contract

`bond_rst_n` is the common session reset. `lane0_rst_n` and
`lane1_rst_n` are lane-local health/reset inputs. A lane reset flushes both
sides of that lane's FIFO; it does not reset the other lane's FIFO.

The asynchronous FIFO asserts reset asynchronously and synchronizes reset
release independently to its write and read clocks. Its ready/valid outputs
remain inactive until the local reset synchronizer has released.

A lane reset must be treated as a coordinated flush of that lane's FIFO.
Do not independently reset only one side of a FIFO while the other side
continues to transfer data. Traffic must be quiesced while reset is asserted
and until both clock domains have completed reset release.

## FIFO implementation notes

The FIFO uses binary pointers locally and Gray-coded pointers across the
clock boundary, with two-stage synchronizers. The read data is first-word
fall-through from the dual-clock memory. FPGA-specific RAM inference and
placement constraints remain to be validated for each target device.

The synchronizer registers carry the `async_reg` attribute. Integrators must
add device/tool-specific constraints for synchronizer placement and Gray-bus
skew/max-delay. These constraints are not inferred from RTL alone.

## Verification

The Icarus Verilog testbenches exercise:
- One asynchronous FIFO with unrelated write/read clocks and consumer stalls.
- Two independent lane clocks feeding a shared bonding clock.
- Per-lane ordering and independent backpressure.

Simulation is a functional check, not metastability analysis or proof of
physical CDC timing closure.
