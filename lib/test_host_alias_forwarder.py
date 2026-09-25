#!/usr/bin/env python3
import importlib.util
import os
import socket
import struct
import threading
import time
import unittest

for _var in list(os.environ):
    if _var.startswith("CBOX_"):
        os.environ.pop(_var, None)

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "host_alias_forwarder",
    os.path.join(HERE, "..", "etc", "net", "host_alias_forwarder.py"),
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class FakeSocket:
    def __init__(self, recv_chunks):
        self.sent = b""
        self._buffer = b"".join(recv_chunks)
        self.timeout = None

    def settimeout(self, value):
        self.timeout = value

    def sendall(self, data):
        self.sent += data

    def recv(self, n):
        chunk = self._buffer[:n]
        self._buffer = self._buffer[n:]
        return chunk


class LoadPortTableTests(unittest.TestCase):
    def write(self, tmp_path, obj):
        import json
        with open(tmp_path, "w", encoding="ascii") as fh:
            fh.write(json.dumps(obj))

    def test_missing_file_yields_empty(self):
        table, proxy = MOD.load_port_table("/does/not/exist/netmap.json")
        self.assertEqual(table, {})
        self.assertIsNone(proxy)

    def test_valid_table_parsed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            self.write(path, {
                "proxy": {"host": "cbox-proxy-internal", "port": 1080},
                "host_aliases": {
                    "ports": {
                        "443": {"container": "revproxy", "container_port": 443, "network": "project_a"},
                    },
                },
            })
            table, proxy = MOD.load_port_table(path)
            self.assertEqual(table, {443: ("revproxy", 443)})
            self.assertEqual(proxy, ("cbox-proxy-internal", 1080))

    def test_malformed_entries_dropped(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            self.write(path, {
                "proxy": {"host": "cbox-proxy-internal", "port": 1080},
                "host_aliases": {
                    "ports": {
                        "443": {"container": "revproxy", "container_port": 443, "network": "project_a"},
                        "not-a-port": {"container": "x", "container_port": 80, "network": "project_a"},
                        "70000": {"container": "x", "container_port": 80, "network": "project_a"},
                        "80": {"container": "x", "container_port": 0, "network": "project_a"},
                        "81": {"container": 123, "container_port": 80, "network": "project_a"},
                    },
                },
            })
            table, proxy = MOD.load_port_table(path)
            self.assertEqual(table, {443: ("revproxy", 443)})

    def test_malformed_json_yields_empty(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            with open(path, "w") as fh:
                fh.write("{ not json")
            table, proxy = MOD.load_port_table(path)
            self.assertEqual(table, {})
            self.assertIsNone(proxy)

    def test_table_size_is_capped(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            ports = {}
            for i in range(MOD.MAX_PORT_TABLE_SIZE + 5):
                ports[str(10000 + i)] = {"container": "c%d" % i, "container_port": 80, "network": "n"}
            self.write(path, {
                "proxy": {"host": "cbox-proxy-internal", "port": 1080},
                "host_aliases": {"ports": ports},
            })
            table, _proxy = MOD.load_port_table(path)
            self.assertEqual(len(table), MOD.MAX_PORT_TABLE_SIZE)


class PortTableReloadTests(unittest.TestCase):
    def test_reload_detects_mtime_change_and_no_change(self):
        import tempfile, json
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            with open(path, "w") as fh:
                json.dump({"proxy": {"host": "p", "port": 1}, "host_aliases": {"ports": {}}}, fh)
            table = MOD.PortTable(path)
            self.assertTrue(table.check_reload())
            self.assertFalse(table.check_reload())
            time.sleep(0.01)
            os.utime(path, None)
            with open(path, "w") as fh:
                json.dump({
                    "proxy": {"host": "p", "port": 1},
                    "host_aliases": {"ports": {"443": {"container": "c", "container_port": 443, "network": "n"}}},
                }, fh)
            self.assertTrue(table.check_reload())
            self.assertEqual(table.table, {443: ("c", 443)})

    def test_reload_handles_disappearing_file(self):
        import tempfile, json
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            with open(path, "w") as fh:
                json.dump({
                    "proxy": {"host": "p", "port": 1},
                    "host_aliases": {"ports": {"443": {"container": "c", "container_port": 443, "network": "n"}}},
                }, fh)
            table = MOD.PortTable(path)
            table.check_reload()
            self.assertEqual(table.table, {443: ("c", 443)})
            os.unlink(path)
            self.assertTrue(table.check_reload())
            self.assertEqual(table.table, {})
            self.assertIsNone(table.proxy)


class Socks5ConnectFramingTests(unittest.TestCase):
    def test_connect_sends_domain_name_atyp_with_exact_bytes(self):
        reply = bytes([5, 0, 0, 1]) + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0)
        fake = FakeSocket([bytes([5, 0]), reply])
        MOD.socks5_connect(fake, "revproxy", 443)
        expected = bytes([5, 1, 0]) + bytes([5, 1, 0, 3, len(b"revproxy")]) + b"revproxy" + struct.pack(">H", 443)
        self.assertEqual(fake.sent, expected)

    def test_connect_accepts_atyp3_and_atyp4_replies(self):
        name = b"whatever"
        reply3 = bytes([5, 0, 0, 3]) + bytes([len(name)]) + name + struct.pack(">H", 0)
        fake3 = FakeSocket([bytes([5, 0]), reply3])
        MOD.socks5_connect(fake3, "c", 80)

        reply4 = bytes([5, 0, 0, 4]) + (b"\x00" * 16) + struct.pack(">H", 0)
        fake4 = FakeSocket([bytes([5, 0]), reply4])
        MOD.socks5_connect(fake4, "c", 80)

    def test_bad_greeting_version_raises(self):
        fake = FakeSocket([bytes([4, 0])])
        with self.assertRaises(ConnectionError):
            MOD.socks5_connect(fake, "c", 80)

    def test_nonzero_rep_raises(self):
        reply = bytes([5, 1, 0, 1]) + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0)
        fake = FakeSocket([bytes([5, 0]), reply])
        with self.assertRaises(ConnectionError):
            MOD.socks5_connect(fake, "c", 80)

    def test_peer_closed_raises(self):
        fake = FakeSocket([bytes([5, 0]), b""])
        with self.assertRaises(ConnectionError):
            MOD.socks5_connect(fake, "c", 80)

    def test_unexpected_atyp_raises(self):
        reply = bytes([5, 0, 0, 9])
        fake = FakeSocket([bytes([5, 0]), reply])
        with self.assertRaises(ConnectionError):
            MOD.socks5_connect(fake, "c", 80)

    def test_host_name_too_long_raises(self):
        fake = FakeSocket([bytes([5, 0])])
        with self.assertRaises(ValueError):
            MOD.socks5_connect(fake, "c" * 256, 80)


class EchoSocks5Stub:
    def __init__(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(4)
        self.port = self.server.getsockname()[1]
        self.stop_flag = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        self.server.settimeout(0.02)
        while not self.stop_flag:
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        conn.settimeout(3)
        try:
            with conn:
                greeting = conn.recv(3)
                if len(greeting) < 3:
                    return
                conn.sendall(bytes([5, 0]))
                header = conn.recv(4)
                atyp = header[3]
                if atyp == 3:
                    n = conn.recv(1)[0]
                    conn.recv(n)
                elif atyp == 1:
                    conn.recv(4)
                conn.recv(2)
                conn.sendall(bytes([5, 0, 0, 1]) + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    conn.sendall(data)
        except OSError:
            pass

    def stop(self):
        self.stop_flag = True
        self.thread.join(timeout=2)
        self.server.close()


class EndToEndRelayTests(unittest.TestCase):
    def test_client_bytes_round_trip_through_listener_and_stub_proxy(self):
        import tempfile, json
        stub = EchoSocks5Stub()
        try:
            with tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, "netmap.json")
                listen_port = free_port()
                with open(path, "w") as fh:
                    json.dump({
                        "proxy": {"host": "127.0.0.1", "port": stub.port},
                        "host_aliases": {"ports": {
                            str(listen_port): {"container": "revproxy", "container_port": 443, "network": "project_a"},
                        }},
                    }, fh)
                stop_event = threading.Event()
                runner = threading.Thread(target=MOD.run, args=(path, 0.05, stop_event), daemon=True)
                runner.start()
                deadline = time.time() + 2
                client = None
                while time.time() < deadline:
                    try:
                        client = socket.create_connection(("127.0.0.1", listen_port), timeout=0.2)
                        break
                    except OSError:
                        time.sleep(0.05)
                self.assertIsNotNone(client, "forwarder never opened its listener")
                try:
                    client.settimeout(2)
                    client.sendall(b"hello world")
                    got = client.recv(64)
                    self.assertEqual(got, b"hello world")
                finally:
                    client.close()
                stop_event.set()
                runner.join(timeout=2)
        finally:
            stub.stop()

    def test_removed_port_stops_accepting(self):
        import tempfile, json
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            listen_port = free_port()
            with open(path, "w") as fh:
                json.dump({
                    "proxy": {"host": "127.0.0.1", "port": 1},
                    "host_aliases": {"ports": {
                        str(listen_port): {"container": "revproxy", "container_port": 443, "network": "project_a"},
                    }},
                }, fh)
            stop_event = threading.Event()
            runner = threading.Thread(target=MOD.run, args=(path, 0.05, stop_event), daemon=True)
            runner.start()
            deadline = time.time() + 2
            ok = False
            while time.time() < deadline:
                try:
                    probe = socket.create_connection(("127.0.0.1", listen_port), timeout=0.2)
                    probe.close()
                    ok = True
                    break
                except OSError:
                    time.sleep(0.05)
            self.assertTrue(ok, "forwarder never opened its listener")
            with open(path, "w") as fh:
                json.dump({"proxy": {"host": "127.0.0.1", "port": 1}, "host_aliases": {"ports": {}}}, fh)
            deadline = time.time() + 2
            closed = False
            while time.time() < deadline:
                try:
                    probe = socket.create_connection(("127.0.0.1", listen_port), timeout=0.2)
                    probe.close()
                    time.sleep(0.05)
                except OSError:
                    closed = True
                    break
            stop_event.set()
            runner.join(timeout=2)
            self.assertTrue(closed, "forwarder kept listening on a port removed from the port table")


class ConnectionSemaphoreTests(unittest.TestCase):
    def test_accept_loop_closes_connection_when_semaphore_exhausted(self):
        original = MOD.CONNECTION_SEMAPHORE
        MOD.CONNECTION_SEMAPHORE = threading.Semaphore(0)
        try:
            table = MOD.PortTable.__new__(MOD.PortTable)
            port = free_port()
            table.table = {port: ("revproxy", 443)}
            table.proxy = ("127.0.0.1", 1)
            listener = MOD.PortListener(port, table)
            listener.start()
            client = socket.create_connection(("127.0.0.1", port), timeout=2)
            try:
                client.settimeout(2)
                got = client.recv(64)
                self.assertEqual(
                    got, b"",
                    "the accept loop must close a new connection immediately once the "
                    "semaphore is exhausted, before ever spawning a handler thread",
                )
            finally:
                client.close()
                listener.stop()
        finally:
            MOD.CONNECTION_SEMAPHORE = original


class RelayIdleTimeoutTests(unittest.TestCase):
    def test_idle_timeout_is_shared_across_both_directions(self):
        orig_idle = MOD.IDLE_TIMEOUT_SEC
        orig_poll = MOD.RELAY_POLL_SEC
        MOD.IDLE_TIMEOUT_SEC = 0.3
        MOD.RELAY_POLL_SEC = 0.05
        conn_near, conn_far = socket.socketpair()
        up_near, up_far = socket.socketpair()
        try:
            activity = MOD.RelayActivity()
            t1 = threading.Thread(
                target=MOD._relay, args=(conn_near, up_near, activity), daemon=True
            )
            t2 = threading.Thread(
                target=MOD._relay, args=(up_near, conn_near, activity), daemon=True
            )
            t1.start()
            t2.start()
            stop_feeding = threading.Event()

            def feed():
                while not stop_feeding.is_set():
                    try:
                        conn_far.sendall(b"x")
                    except OSError:
                        return
                    time.sleep(0.05)

            feeder = threading.Thread(target=feed, daemon=True)
            feeder.start()
            try:
                time.sleep(0.6)
                self.assertTrue(
                    t1.is_alive() and t2.is_alive(),
                    "one-way traffic on conn->upstream must keep the whole relay "
                    "alive even though upstream->conn has been idle the whole time",
                )
            finally:
                stop_feeding.set()
                feeder.join(timeout=2)
            up_far.settimeout(2)
            deadline = time.time() + 2
            closed = False
            while time.time() < deadline:
                try:
                    got = up_far.recv(64)
                except socket.timeout:
                    continue
                if got == b"":
                    closed = True
                    break
            self.assertTrue(
                closed,
                "once both directions go idle past IDLE_TIMEOUT_SEC the relay must stop",
            )
            t1.join(timeout=2)
            t2.join(timeout=2)
        finally:
            MOD.IDLE_TIMEOUT_SEC = orig_idle
            MOD.RELAY_POLL_SEC = orig_poll
            for s in (conn_near, conn_far, up_near, up_far):
                try:
                    s.close()
                except OSError:
                    pass


class PortListenerActiveConnectionTests(unittest.TestCase):
    def test_stop_closes_active_connections(self):
        stub = EchoSocks5Stub()
        try:
            table = MOD.PortTable.__new__(MOD.PortTable)
            port = free_port()
            table.table = {port: ("revproxy", 443)}
            table.proxy = ("127.0.0.1", stub.port)
            listener = MOD.PortListener(port, table)
            listener.start()
            try:
                client = None
                deadline = time.time() + 2
                while time.time() < deadline:
                    try:
                        client = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                        break
                    except OSError:
                        time.sleep(0.05)
                self.assertIsNotNone(client, "listener never accepted")
                client.settimeout(2)
                client.sendall(b"ping")
                self.assertEqual(client.recv(64), b"ping")
                deadline = time.time() + 2
                while time.time() < deadline and not listener.active:
                    time.sleep(0.02)
                self.assertTrue(listener.active, "connection was never tracked as active")
                listener.stop()
                client.settimeout(0.2)
                deadline = time.time() + 2
                closed = False
                while time.time() < deadline:
                    try:
                        got = client.recv(64)
                    except socket.timeout:
                        continue
                    except OSError:
                        closed = True
                        break
                    if got == b"":
                        closed = True
                        break
                self.assertTrue(closed, "stop() did not close the active connection")
                client.close()
            finally:
                listener.stop()
        finally:
            stub.stop()


class BindRetryLoggingTests(unittest.TestCase):
    def test_bind_failure_logs_once_across_reloads(self):
        import contextlib
        import io
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "netmap.json")
            port = free_port()
            blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            blocker.bind(("127.0.0.1", port))
            blocker.listen(1)
            try:
                with open(path, "w") as fh:
                    json.dump({
                        "proxy": {"host": "127.0.0.1", "port": 1},
                        "host_aliases": {"ports": {
                            str(port): {"container": "revproxy", "container_port": 443, "network": "n"},
                        }},
                    }, fh)
                stop_event = threading.Event()
                buf = io.StringIO()
                with contextlib.redirect_stderr(buf):
                    runner = threading.Thread(target=MOD.run, args=(path, 0.02, stop_event), daemon=True)
                    runner.start()
                    time.sleep(0.3)
                    stop_event.set()
                    runner.join(timeout=2)
                lines = [l for l in buf.getvalue().splitlines() if "cannot bind" in l]
                self.assertEqual(len(lines), 1)
            finally:
                blocker.close()


if __name__ == "__main__":
    unittest.main()
