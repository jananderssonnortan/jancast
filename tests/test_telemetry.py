"""telemetry.py: seq/since semantics, counters, network summary, thread safety."""

import threading
import time
import unittest

from jancast import telemetry
from jancast.telemetry import Telemetry


def req(t=None, kind="segment", status=200, error=None, ratio=None, path="/seg_video_00000.m4s"):
    return {"t": time.time() if t is None else t, "path": path, "kind": kind, "segment": 0,
            "status": status, "bytes": 0, "duration_ms": 1.0, "mbps": None,
            "realtime_ratio": ratio, "client": "192.0.2.20", "error": error}


class SeqTest(unittest.TestCase):
    def test_seq_shared_and_increasing(self):
        tm = Telemetry()
        tm.event("info", "app", "a")
        tm.request(req())
        s = tm.sample({"ff_speed": 1.0})
        self.assertEqual([tm.events[0]["seq"], tm.requests[0]["seq"], s["seq"]], [1, 2, 3])
        self.assertEqual(tm.seq, 3)
        self.assertEqual(s["ff_speed"], 1.0)
        for key in ("seq", "t", "tx_bps", "requests", "rtt_ms"):
            self.assertIn(key, s)

    def test_since_zero_returns_capped_recent_history(self):
        tm = Telemetry()
        for i in range(1000):
            tm.sample({"i": i})
        for i in range(500):
            tm.request(req())
        for i in range(400):
            tm.event("info", "app", str(i))
        samples, requests, events = tm.since(0)
        self.assertEqual(len(samples), telemetry.INITIAL_SAMPLES)
        self.assertEqual(len(requests), telemetry.INITIAL_REQUESTS)
        self.assertEqual(len(events), telemetry.INITIAL_EVENTS)
        self.assertEqual(samples[-1]["i"], 999)       # most recent, not oldest
        self.assertEqual(events[-1]["message"], "399")
        self.assertEqual(tm.since(None), tm.since(0))

    def test_since_incremental(self):
        tm = Telemetry()
        tm.event("info", "app", "old")
        tm.sample({})
        mark = tm.seq
        self.assertEqual(tm.since(mark), ([], [], []))
        tm.request(req())
        tm.event("warn", "http", "new")
        samples, requests, events = tm.since(mark)
        self.assertEqual(samples, [])
        self.assertEqual(len(requests), 1)
        self.assertEqual([e["message"] for e in events], ["new"])
        self.assertTrue(all(x["seq"] > mark for x in requests + events))

    def test_snapshot_seq_is_consistent(self):
        tm = Telemetry()
        tm.event("info", "app", "a")
        seq, samples, requests, events = tm.snapshot(0)
        self.assertEqual(seq, 1)
        self.assertEqual(len(events), 1)
        self.assertEqual(tm.snapshot(seq), (1, [], [], []))

    def test_bounded(self):
        tm = Telemetry()
        for _ in range(telemetry.MAX_EVENTS + 10):
            tm.event("info", "app", "x")
        self.assertEqual(len(tm.events), telemetry.MAX_EVENTS)


class CountersTest(unittest.TestCase):
    def test_sample_drains_counters(self):
        tm = Telemetry()
        tm.add_tx_bytes(1000)
        tm.add_tx_bytes(250)
        tm.request(req())
        tm.request(req())
        s = tm.sample({})
        self.assertEqual((s["tx_bps"], s["requests"]), (10000, 2))
        s = tm.sample({})
        self.assertEqual((s["tx_bps"], s["requests"]), (0, 0))

    def test_request_classification(self):
        tm = Telemetry()
        tm.request(req(error="client aborted"))
        tm.request(req(status=404, error="not ready (404)"))
        tm.request(req(status=500, error="OSError: x"))
        tm.request(req(status=503))
        tm.request(req(status=206))
        self.assertEqual((tm.client_aborts, tm.not_ready, tm.http_errors), (1, 1, 2))
        tm.reset_counters()
        self.assertEqual((tm.client_aborts, tm.not_ready, tm.http_errors), (0, 0, 0))
        self.assertEqual(len(tm.requests), 5)              # history kept

    def test_recent_windows(self):
        tm = Telemetry()
        tm.request(req(t=time.time() - 120))
        tm.request(req())
        self.assertEqual(len(tm.recent_requests(60)), 1)
        tm.sample({})
        tm.samples[0]["t"] -= 100
        self.assertEqual(tm.recent_samples(60), [])


class NetworkSummaryTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(Telemetry().network_summary(), {
            "tx_bps_now": 0, "tx_bps_avg10": 0, "rtt_ms": None, "rtt_ms_avg": None,
            "rtt_loss": 0.0, "http_errors": 0, "client_aborts": 0})

    def test_rtt_with_timeouts(self):
        tm = Telemetry()
        for ms in (4.0, None, 6.0, None):
            tm.rtt(ms)
        n = tm.network_summary()
        self.assertEqual((n["rtt_ms"], n["rtt_ms_avg"], n["rtt_loss"]), (None, 5.0, 0.5))
        for _ in range(3):
            tm.rtt(None)
        tm2 = Telemetry()
        tm2.rtt(None)
        n = tm2.network_summary()
        self.assertEqual((n["rtt_ms_avg"], n["rtt_loss"]), (None, 1.0))

    def test_tx_averages(self):
        tm = Telemetry()
        for i in range(15):
            tm.add_tx_bytes(i * 1000)
            tm.sample({})
        n = tm.network_summary()
        self.assertEqual(n["tx_bps_now"], 14 * 8000)
        self.assertEqual(n["tx_bps_avg10"], int(sum(i * 8000 for i in range(5, 15)) / 10))


class ThreadSafetyTest(unittest.TestCase):
    def test_concurrent_producers_and_consumer(self):
        tm = Telemetry()
        n_threads, n = 8, 100     # stay under the deque caps
        stop = threading.Event()
        seen = []
        errors = []

        def produce():
            try:
                for i in range(n):
                    tm.event("info", "app", "x")
                    tm.request(req())
                    tm.add_tx_bytes(1)
                    tm.rtt(1.0 if i % 2 else None)
            except Exception as e:  # noqa: BLE001
                errors.append(e)

        def consume():
            last = 0
            while not stop.is_set():
                try:
                    seq, _, requests, events = tm.snapshot(last)
                    seen.extend(x["seq"] for x in requests + events)
                    last = seq
                    tm.network_summary()
                    tm.sample({})
                except Exception as e:  # noqa: BLE001
                    errors.append(e)

        consumer = threading.Thread(target=consume)
        consumer.start()
        producers = [threading.Thread(target=produce) for _ in range(n_threads)]
        for t in producers:
            t.start()
        for t in producers:
            t.join()
        stop.set()
        consumer.join()
        self.assertEqual(errors, [])
        total = n_threads * n * 2
        self.assertEqual(len(tm.requests) + len(tm.events), total)
        seqs = [x["seq"] for x in list(tm.requests) + list(tm.events)]
        self.assertEqual(len(set(seqs)), total)
        # The poller following snapshot() seqs got every item exactly once.
        _, _, requests, events = tm.snapshot(max(seen) if seen else 0)
        seen.extend(x["seq"] for x in requests + events)
        self.assertEqual(sorted(seen), sorted(seqs))
        sent = sum(s["tx_bps"] for s in tm.samples) + tm.sample({})["tx_bps"]
        self.assertEqual(sent, n_threads * n * 8)


if __name__ == "__main__":
    unittest.main()
