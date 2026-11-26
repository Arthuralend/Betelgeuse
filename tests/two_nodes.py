"""Real-process acceptance test. No central service is launched."""
import argparse
import json
import os
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time

class Node:
    def __init__(self, binary, directory, bootstrap=None, relay_server=False):
        args = [binary, "--data-dir", str(directory), "node", "start", "--server"]
        if bootstrap:
            args += ["--bootstrap", bootstrap]
        if relay_server:
            args += ["--relay-server"]
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", bufsize=1)
        self.queue = queue.Queue()
        self.previous = []
        self.log = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.log.append(line.rstrip())
            print(line.rstrip(), flush=True)
            try:
                self.queue.put(json.loads(line))
            except json.JSONDecodeError:
                pass

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def wait(self, event, predicate=lambda _: True, timeout=45):
        for i, item in enumerate(self.previous):
            if item.get("event") == event and predicate(item):
                return self.previous.pop(i)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                item = self.queue.get(timeout=min(0.25, max(0, deadline - time.monotonic())))
            except queue.Empty:
                if self.process.poll() is not None:
                    raise AssertionError(f"Node exited: {self.log[-30:]}")
                continue
            if item.get("event") == "error":
                raise AssertionError(item)
            if item.get("event") == event and predicate(item):
                return item
            self.previous.append(item)
        raise AssertionError(f"Timed out waiting for {event}: {self.log[-30:]}")

    def stop(self):
        if self.process.poll() is None:
            try:
                self.send(op="quit")
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)

def invoke(binary, directory, *command):
    return json.loads(subprocess.check_output([binary, "--data-dir", str(directory), *command], text=True))

def qr_decode(svg, link, require):
    convert, scan = shutil.which("rsvg-convert"), shutil.which("zbarimg")
    if not (convert and scan):
        if require:
            raise AssertionError("QR scanner tools not installed")
        return link
    png = svg.with_suffix(".png")
    subprocess.run([convert, "-o", str(png), str(svg)], check=True)
    scanned = subprocess.check_output([scan, "--quiet", "--raw", str(png)], text=True).strip()
    assert scanned == link
    return scanned

def run(binary, require_qr):
    with tempfile.TemporaryDirectory(prefix="betelgeuse-test-") as directory:
        root = pathlib.Path(directory)
        a_dir, b_dir = root / "alice", root / "bob"
        alice = invoke(binary, a_dir, "account", "create")["peer"]
        bob = invoke(binary, b_dir, "account", "create")["peer"]
        assert alice != bob
        assert invoke(binary, a_dir, "account", "show")["peer"] == alice
        a = Node(binary, a_dir)
        b = None
        try:
            a.wait("started", lambda e: e["peer"] == alice)
            address = a.wait("listen")["address"]
            b = Node(binary, b_dir, address)
            b.wait("started", lambda e: e["peer"] == bob)
            b.wait("listen")
            a.wait("identified", lambda e: e["peer"] == bob)
            b.wait("identified", lambda e: e["peer"] == alice)
            a.send(op="invite", name="Alice", qr_path=str(root / "alice.svg"))
            invite_a = a.wait("invite")["link"]
            b.send(op="invite", name="Bob", qr_path=str(root / "bob.svg"))
            invite_b = b.wait("invite")["link"]
            b.send(op="import", link=qr_decode(root / "alice.svg", invite_a, require_qr))
            a.send(op="import", link=qr_decode(root / "bob.svg", invite_b, require_qr))
            b.wait("contact", lambda e: e["contact"]["peer"] == alice)
            a.wait("contact", lambda e: e["contact"]["peer"] == bob)
            a.send(op="put", name="Alice")
            first = a.wait("put")
            assert first["ok"], first
            b.wait("record_stored", lambda e: e["record"]["body"]["peer"] == alice and
                e["record"]["body"]["sequence"] == first["record"]["body"]["sequence"])
            a.send(op="put", name="Alice v2")
            second = a.wait("put")
            assert second["ok"], second
            assert second["record"]["body"]["sequence"] > first["record"]["body"]["sequence"]
            b.wait("record_stored", lambda e: e["record"]["body"]["sequence"] == second["record"]["body"]["sequence"])
            # Restart Bob. Its SQLite replay protection remains, but the DHT
            # MemoryStore is empty, so GET must fetch the record from Alice.
            b.stop()
            assert invoke(binary, b_dir, "account", "show")["peer"] == bob
            b = Node(binary, b_dir, address)
            b.wait("started", lambda e: e["peer"] == bob)
            b.wait("identified", lambda e: e["peer"] == alice)
            b.send(op="get", peer=alice)
            found = b.wait("get")
            assert found["ok"] and found["source"] == alice, found
            assert found["record"]["body"]["payload"]["name"] == "Alice v2", found
            b.send(op="send", peer=alice, text="Real libp2p message")
            message = b.wait("queued")
            a.wait("message", lambda e: e["id"] == message["id"] and e["text"] == "Real libp2p message")
            delivery = b.wait("delivery", lambda e: e["id"] == message["id"])
            assert delivery["ok"], delivery
            print("Two independent libp2p nodes, signed DHT records, QR invitation and message ACK: PASS")
        finally:
            a.stop()
            if b:
                b.stop()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="./target/debug/betelgeuse")
    parser.add_argument("--require-qr", action="store_true")
    args = parser.parse_args()
    run(os.path.abspath(args.binary), args.require_qr)
