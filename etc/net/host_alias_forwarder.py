#!/usr/bin/env python3
import json
import os
import socket
import struct
import sys
import threading
import time

NETMAP_PATH_ENV = "CBOX_NETMAP_FILE"
DEFAULT_NETMAP_PATH = "/etc/cbox/net/netmap.json"
RELOAD_INTERVAL_SEC = 3
CONNECT_TIMEOUT_SEC = 10
RELAY_BUF_SIZE = 65536
MAX_NETMAP_BYTES = 1048576
SOCKS_VERSION = 0x05
MAX_PORT_TABLE_SIZE = 64
MAX_CONCURRENT_CONNECTIONS = 128
IDLE_TIMEOUT_SEC = 300
RELAY_POLL_SEC = 5


def netmap_path():
    return os.environ.get(NETMAP_PATH_ENV, "").strip() or DEFAULT_NETMAP_PATH


def load_port_table(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read(MAX_NETMAP_BYTES + 1)
    except OSError:
        return {}, None
    if len(data) > MAX_NETMAP_BYTES:
        return {}, None
    try:
        obj = json.loads(data.decode("utf-8"))
    except ValueError:
        return {}, None
    if not isinstance(obj, dict):
        return {}, None
    proxy = obj.get("proxy") if isinstance(obj.get("proxy"), dict) else {}
    host_aliases = obj.get("host_aliases") if isinstance(obj.get("host_aliases"), dict) else {}
    ports = host_aliases.get("ports") if isinstance(host_aliases.get("ports"), dict) else {}
    table = {}
    for host_port, entry in ports.items():
        if not isinstance(host_port, str) or not host_port.isdigit():
            continue
        port = int(host_port)
        if not (1 <= port <= 65535):
            continue
        if not isinstance(entry, dict):
            continue
        container = entry.get("container")
        container_port = entry.get("container_port")
        if not isinstance(container, str) or not container:
            continue
        if not isinstance(container_port, int) or isinstance(container_port, bool) \
                or not (1 <= container_port <= 65535):
            continue
        if len(table) >= MAX_PORT_TABLE_SIZE and port not in table:
            continue
        table[port] = (container, container_port)
    proxy_host = proxy.get("host")
    proxy_port = proxy.get("port")
    if not isinstance(proxy_host, str) or not proxy_host:
        return table, None
    if not isinstance(proxy_port, int) or isinstance(proxy_port, bool) or not (1 <= proxy_port <= 65535):
        return table, None
    return table, (proxy_host, proxy_port)


class PortTable:
    def __init__(self, path):
        self.path = path
        self.mtime = None
        self.table = {}
        self.proxy = None

    def check_reload(self):
        try:
            st = os.stat(self.path)
        except OSError:
            changed = bool(self.table) or self.proxy is not None
            self.mtime = None
            self.table = {}
            self.proxy = None
            return changed
        if self.mtime is not None and st.st_mtime == self.mtime:
            return False
        table, proxy = load_port_table(self.path)
        self.mtime = st.st_mtime
        changed = table != self.table or proxy != self.proxy
        self.table = table
        self.proxy = proxy
        return changed


def _recv_exact(sock, count):
    chunks = []
    remaining = count
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("socks5 peer closed the connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def socks5_connect(sock, target_host, target_port, timeout=CONNECT_TIMEOUT_SEC):
    sock.settimeout(timeout)
    sock.sendall(bytes([SOCKS_VERSION, 1, 0x00]))
    greeting = _recv_exact(sock, 2)
    if greeting[0] != SOCKS_VERSION or greeting[1] != 0x00:
        raise ConnectionError("socks5 handshake rejected: %r" % (greeting,))
    host_bytes = target_host.encode("ascii")
    if not (1 <= len(host_bytes) <= 255):
        raise ValueError("target host name length out of range: %r" % target_host)
    request = bytes([SOCKS_VERSION, 0x01, 0x00, 0x03, len(host_bytes)]) \
        + host_bytes + struct.pack(">H", target_port)
    sock.sendall(request)
    reply_head = _recv_exact(sock, 4)
    version, rep, _rsv, atyp = reply_head
    if version != SOCKS_VERSION:
        raise ConnectionError("unexpected socks5 reply version: %d" % version)
    if rep != 0x00:
        raise ConnectionError("socks5 CONNECT failed, rep=%d" % rep)
    if atyp == 0x01:
        _recv_exact(sock, 4 + 2)
    elif atyp == 0x03:
        length = _recv_exact(sock, 1)[0]
        _recv_exact(sock, length + 2)
    elif atyp == 0x04:
        _recv_exact(sock, 16 + 2)
    else:
        raise ConnectionError("unexpected ATYP in socks5 reply: %d" % atyp)


CONNECTION_SEMAPHORE = threading.Semaphore(MAX_CONCURRENT_CONNECTIONS)


class RelayActivity:
    def __init__(self):
        self._lock = threading.Lock()
        self._last = time.monotonic()

    def touch(self):
        with self._lock:
            self._last = time.monotonic()

    def idle_seconds(self):
        with self._lock:
            return time.monotonic() - self._last


def _relay(src, dst, activity):
    try:
        src.settimeout(RELAY_POLL_SEC)
        while True:
            try:
                data = src.recv(RELAY_BUF_SIZE)
            except socket.timeout:
                if activity.idle_seconds() >= IDLE_TIMEOUT_SEC:
                    break
                continue
            if not data:
                break
            activity.touch()
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle_connection(conn, container, container_port, proxy_addr, register=None, unregister=None):
    if register is not None:
        register(conn)
    upstream = None
    try:
        try:
            upstream = socket.create_connection(proxy_addr, timeout=CONNECT_TIMEOUT_SEC)
            if register is not None:
                register(upstream)
            socks5_connect(upstream, container, container_port)
        except (OSError, ValueError):
            conn.close()
            if upstream is not None:
                upstream.close()
            return
        activity = RelayActivity()
        t1 = threading.Thread(target=_relay, args=(conn, upstream, activity), daemon=True)
        t2 = threading.Thread(target=_relay, args=(upstream, conn, activity), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        conn.close()
        upstream.close()
    finally:
        if unregister is not None:
            unregister(conn)
            if upstream is not None:
                unregister(upstream)
        CONNECTION_SEMAPHORE.release()


class PortListener:
    def __init__(self, port, table):
        self.port = port
        self.table = table
        self.stop_flag = False
        self.active = set()
        self.active_lock = threading.Lock()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(16)
        self.sock.settimeout(0.5)
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)

    def start(self):
        self.thread.start()

    def _register(self, sock_):
        with self.active_lock:
            self.active.add(sock_)

    def _unregister(self, sock_):
        with self.active_lock:
            self.active.discard(sock_)

    def _accept_loop(self):
        while not self.stop_flag:
            try:
                conn, _addr = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            entry = self.table.table.get(self.port)
            proxy = self.table.proxy
            if not entry or not proxy:
                conn.close()
                continue
            if not CONNECTION_SEMAPHORE.acquire(blocking=False):
                conn.close()
                continue
            container, container_port = entry
            threading.Thread(
                target=handle_connection,
                args=(conn, container, container_port, proxy),
                kwargs={"register": self._register, "unregister": self._unregister},
                daemon=True,
            ).start()

    def stop(self):
        self.stop_flag = True
        try:
            self.sock.close()
        except OSError:
            pass
        with self.active_lock:
            socks = list(self.active)
            self.active.clear()
        for sock_ in socks:
            try:
                sock_.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock_.close()
            except OSError:
                pass


def run(path, poll_interval=RELOAD_INTERVAL_SEC, stop_event=None):
    table = PortTable(path)
    listeners = {}
    bind_failed_logged = set()
    while stop_event is None or not stop_event.is_set():
        table.check_reload()
        current_ports = set(table.table.keys())
        for port in list(listeners.keys()):
            if port not in current_ports:
                listeners.pop(port).stop()
        bind_failed_logged &= current_ports
        for port in current_ports:
            if port in listeners:
                continue
            try:
                listener = PortListener(port, table)
            except OSError as exc:
                if port not in bind_failed_logged:
                    sys.stderr.write(
                        "host_alias_forwarder: cannot bind 127.0.0.1:%d: %s\n" % (port, exc)
                    )
                    bind_failed_logged.add(port)
                continue
            bind_failed_logged.discard(port)
            listener.start()
            listeners[port] = listener
        time.sleep(poll_interval)


def main():
    try:
        run(netmap_path())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
