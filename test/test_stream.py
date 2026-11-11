#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Simulation of the stream port (credit-based flow control) over two link layers connected
# back-to-back with SerWB register access (see test_link.py, which also covers the link flow control).

import unittest

from migen import *

from litex.gen import *

from soc2soc.stream import SerWBStreamPort, StreamTester

from test.test_link import _DUT, CLOCKS, wait_ready, wb_access # Also applies the Migen compatibility shim.

# Helpers ------------------------------------------------------------------------------------------

STREAM_KWARGS = dict(rx_buffer_depth=32, max_packet_words=8, credit_timeout=32, flush_timeout=8)

class _StreamDUT(_DUT):
    """test_link DUT (A initiator ... B target -> SRAM) with a stream port on each side."""
    def __init__(self, with_testers=False, **kwargs):
        _DUT.__init__(self, **kwargs)
        self.stream_a = SerWBStreamPort(self.core_a, ready=self.phy_a.init.ready, **STREAM_KWARGS)
        self.stream_b = SerWBStreamPort(self.core_b, ready=self.phy_b.init.ready, **STREAM_KWARGS)
        if with_testers:
            self.tester_a = StreamTester()
            self.tester_b = StreamTester()
            for s, t in [(self.stream_a, self.tester_a), (self.stream_b, self.tester_b)]:
                self.comb += [
                    t.source.connect(s.sink),
                    s.source.connect(t.sink),
                ]

def push_words(sink, words, lasts, pushed):
    """Push words to a stream sink, ``pushed[0]`` records the count."""
    for i, w in enumerate(words):
        yield sink.valid.eq(1)
        yield sink.data.eq(w)
        yield sink.last.eq(lasts[i])
        yield
        while not (yield sink.ready):
            yield
        pushed[0] = i + 1
    yield sink.valid.eq(0)

def mmap_test(dut, adr, value):
    """Remote write + read through the initiator (register access), returns True if OK."""
    _, err  = yield from wb_access(dut.host, dut.host_base + adr, value)
    dat, err2 = yield from wb_access(dut.host, dut.host_base + adr)
    return (not err) and (not err2) and (dat == value)

# Stream Port --------------------------------------------------------------------------------------

class TestStream(unittest.TestCase):
    def test_stream_bidirectional_throttled(self):
        # Both directions with testers, slow consumer on B (1 word / 4 cycles), short frames, and
        # register access during streaming.
        dut     = _StreamDUT(with_testers=True)
        results = {}

        def generator():
            for t in [dut.tester_a, dut.tester_b]:
                yield t._frame_words.storage.eq(5)
            yield dut.tester_b._rx_throttle.storage.eq(3)
            yield from wait_ready(dut)
            for t in [dut.tester_a, dut.tester_b]:
                # TX + RX enable (CSR fields are set directly in simulation).
                yield t._control.fields.tx_enable.eq(1)
                yield t._control.fields.rx_enable.eq(1)
            for _ in range(1500):
                yield
            for name, t in [("a", dut.tester_a), ("b", dut.tester_b)]:
                results[f"{name}_rx_words"]     = (yield t._rx_words.status)
                results[f"{name}_rx_errors"]    = (yield t._rx_errors.status)
                results[f"{name}_frame_errors"] = (yield t._rx_frame_errors.status)
            for name, s in [("a", dut.stream_a), ("b", dut.stream_b)]:
                results[f"{name}_overflows"] = (yield s.rx_overflows)
            results["mmap"] = yield from mmap_test(dut, 4, 0x12345678)

        run_simulation(dut, generator(), clocks=CLOCKS)
        for name in ["a", "b"]:
            self.assertGreater(results[f"{name}_rx_words"], 50)
            self.assertEqual(results[f"{name}_rx_errors"], 0)
            self.assertEqual(results[f"{name}_frame_errors"], 0)
            self.assertEqual(results[f"{name}_overflows"], 0)
        # Throttled consumer (B) receives less than the full-speed one (A).
        self.assertLess(results["b_rx_words"], results["a_rx_words"])
        self.assertTrue(results["mmap"], "Register access failed during streaming.")

    def test_stream_stalled_consumer(self):
        # B never consumes: A's stream must stop on credits while register access keeps working,
        # then all data is received in order once B consumes.
        dut     = _StreamDUT()
        n       = 80 # > B RX buffer (32) + A TX buffering (16).
        words   = [0xa000_0000 + i for i in range(n)]
        lasts   = [int(i % 10 == 9) for i in range(n)]
        pushed  = [0]
        results = {"received": []}

        def sender():
            yield from wait_ready(dut)
            yield from push_words(dut.stream_a.sink, words, lasts, pushed)

        def checker():
            yield dut.stream_b.source.ready.eq(0)
            yield from wait_ready(dut)
            for _ in range(500):
                yield
            results["pushed_while_stalled"] = pushed[0]
            results["credits"] = (yield dut.stream_a.tx_credits)
            results["mmap"]    = yield from mmap_test(dut, 8, 0xcafe0001)
            # Consume.
            yield dut.stream_b.source.ready.eq(1)
            yield # ready applied on next cycle.
            for _ in range(3000):
                if (yield dut.stream_b.source.valid):
                    results["received"].append(((yield dut.stream_b.source.data), (yield dut.stream_b.source.last)))
                    if len(results["received"]) == n:
                        break
                yield
            results["overflows"] = (yield dut.stream_b.rx_overflows)

        run_simulation(dut, [sender(), checker()], clocks=CLOCKS)
        self.assertLess(results["pushed_while_stalled"], n)
        self.assertLess(results["credits"], STREAM_KWARGS["max_packet_words"]) # Out of credits.
        self.assertTrue(results["mmap"], "Register access blocked by stalled stream.")
        self.assertEqual(results["received"], list(zip(words, lasts)))
        self.assertEqual(results["overflows"], 0)

if __name__ == "__main__":
    unittest.main()
