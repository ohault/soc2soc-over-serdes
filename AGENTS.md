# AGENTS.md: soc2soc-over-serdes

SoC-to-SoC links over the GTP transceivers of LiteX Acorn Baseboard Mini boards (SFP, DAC cables).
See README.md for the design and docs/test-procedure.md for building and testing on hardware.

## Shared bench: lock, release, restore

Several sessions (people or agents) can use the same boards. **Take the lock of every board you use,
release it when done, and leave the boards in the known state.**

1. **Lock before touching a board.** Touching a board means loading or flashing it, resetting it,
   stopping or restarting its `litex_server`, or running a test that drops its links (`prbs`,
   `autopolarity`, `wiring`, `run`, the stream tests). Pick a name for your session and take the
   locks of all the boards at once:
   ```sh
   export SOC2SOC_LOCK_OWNER=<session-name>
   ./board_lock.py acquire 1-3 1-5 --purpose="<what you are doing>"
   ```
   `acorn_soc2soc.py --load/--flash --usb-port=<port>` refuses a board locked by another owner.
2. **Lock the cabled peers too.** Reprogramming or resetting a board drops the links of the boards
   cabled to it and corrupts their counters. Between boards (scenarios 2 and 3), lock both A and B.
3. **If a board is locked by someone else, stop and report it** (`./board_lock.py status` shows who,
   what and since when). Never `--force` a release unless the user confirms the holder is gone.
4. **Restore the known state, then release:** `./board_lock.py release 1-3 1-5`.

### Bench inventory

| Board | Host USB port | UART | `litex_server` port |
|-------|---------------|------|---------------------|
| A | `1-3` | `/dev/serial/by-path/pci-0000:00:14.0-usb-0:3:1.1-port0` | 1234 |
| B | `1-5` | `/dev/serial/by-path/pci-0000:00:14.0-usb-0:5:1.1-port0` | 1235 |

### Known state

- Both boards run, in SRAM, the `main` build of `./acorn_soc2soc.py --with-stream` (`build/sqrl_acorn`).
- One `litex_server` per board, on the ports above.
- Link counters cleared, and `./test_soc2soc.py --boards=AB status` shows every connected SFP link
  ready, with 0 RX errors, 0 link drops and 0 overflows.

To restore it (with the locks held):
```sh
./acorn_soc2soc.py --with-stream --load --usb-port=1-3
./acorn_soc2soc.py --with-stream --load --usb-port=1-5
# Restart each litex_server (stop the old one by PID first):
nohup litex_server --uart --uart-port=/dev/serial/by-path/pci-0000:00:14.0-usb-0:3:1.1-port0 --bind-port=1234 > /tmp/litex_server_A.log 2>&1 &
nohup litex_server --uart --uart-port=/dev/serial/by-path/pci-0000:00:14.0-usb-0:5:1.1-port0 --bind-port=1235 > /tmp/litex_server_B.log 2>&1 &
./test_soc2soc.py --boards=AB reset-counters   # Reloading a board corrupts its peers' counters.
./test_soc2soc.py --boards=AB status
```

### Rules

- Load into SRAM (`--load`). Never write the SPI flash (`--flash`) unless the user asks.
- Stop a `litex_server` by PID, not with `pkill -f`: an unanchored pattern also matches the shell
  command that runs it. Anchor it on the Python process:
  `pgrep -f '^[^ ]*python[^ ]* [^ ]*litex_server .*--bind-port=1234'`.
- Work on other projects (e.g. a LiteICLink clone) in their own directory, without changing the
  LiteX installation used by this project.
