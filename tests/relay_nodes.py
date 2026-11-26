"""Three real peers using the standard libp2p Circuit Relay v2 protocol."""
import argparse
import os
import pathlib
import tempfile
from two_nodes import Node, invoke

def main(binary):
    with tempfile.TemporaryDirectory(prefix="betelgeuse-relay-") as directory:
        root = pathlib.Path(directory)
        nodes = []
        try:
            r_id = invoke(binary, root / "relay", "account", "create")["peer"]
            a_id = invoke(binary, root / "alice", "account", "create")["peer"]
            b_id = invoke(binary, root / "bob", "account", "create")["peer"]
            r = Node(binary, root / "relay", relay_server=True)
            nodes.append(r)
            r_address = r.wait("listen")["address"]
            r.send(op="announce", address=r_address)
            r.wait("announced")
            a = Node(binary, root / "alice", r_address)
            nodes.append(a)
            a.wait("connected", lambda e: e["peer"] == r_id)
            a.wait("listen")
            a.send(op="reserve_relay", address=r_address)
            relay_address = a.wait("listen", lambda e: "/p2p-circuit/" in e["address"])["address"]
            a.wait("relay_reserved", lambda e: e["relay"] == r_id)
            b = Node(binary, root / "bob", r_address)
            nodes.append(b)
            b.wait("connected", lambda e: e["peer"] == r_id)
            b.wait("listen")
            a.send(op="invite", name="Alice", addresses=[relay_address.rsplit("/p2p/", 1)[0]])
            a_invite = a.wait("invite")["link"]
            b.send(op="invite", name="Bob")
            b_invite = b.wait("invite")["link"]
            b.send(op="import", link=a_invite)
            a.send(op="import", link=b_invite)
            a.wait("contact")
            b.wait("contact")
            b.send(op="connect", address=relay_address)
            b.wait("connected", lambda e: e["peer"] == a_id and e["route"] == "relay")
            a.wait("connected", lambda e: e["peer"] == b_id and e["route"] == "relay")
            b.send(op="send", peer=a_id, text="Circuit Relay v2 message")
            queued = b.wait("queued")
            a.wait("message", lambda e: e["id"] == queued["id"])
            assert b.wait("delivery", lambda e: e["id"] == queued["id"])["ok"]
            print("Relay reservation, actual relayed connection and message ACK: PASS")
        finally:
            for node in reversed(nodes):
                node.stop()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="./target/debug/betelgeuse")
    args = parser.parse_args()
    main(os.path.abspath(args.binary))
