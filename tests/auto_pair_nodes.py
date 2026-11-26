"""Acceptance: trusted automatic bootstrap, verified mutual contact pairing,
route publication, persisted configuration and reconnect (local CLI nodes)."""
import argparse, os, tempfile, time
from pathlib import Path
from two_nodes import Node, invoke

def run(binary):
    with tempfile.TemporaryDirectory(prefix="bgl-auto-") as tmp:
        root=Path(tmp); nodes=[]
        try:
            relay_id=invoke(binary,root/"relay","account","create")["peer"]
            aid=invoke(binary,root/"alice","account","create")["peer"]
            bid=invoke(binary,root/"bob","account","create")["peer"]
            relay=Node(binary,root/"relay",relay_server=True);nodes.append(relay)
            addr=relay.wait("listen")["address"]
            relay.send(op="announce",address=addr);relay.wait("announced")
            a=Node(binary,root/"alice");nodes.append(a)
            a_addr=a.wait("listen")["address"]
            b=Node(binary,root/"bob");nodes.append(b)
            b_addr=b.wait("listen")["address"]
            conf=lambda name:{"enabled":True,"name":name,"addresses":[addr]}
            for n,name in ((a,"Alice"),(b,"Bob")):
                n.send(op="configure_network",settings=conf(name))
                n.wait("network_state",lambda e:e["state"]=="configured")
            for n in (a,b):
                n.wait("network_state",lambda e:e["state"]=="ready",timeout=40)
                n.wait("listen",lambda e:"/p2p-circuit/" in e["address"])
            a.wait("put",lambda e:e["ok"] and e["record"]["body"]["payload"]["type"]=="routes",timeout=40)
            b.wait("put",lambda e:e["ok"] and e["record"]["body"]["payload"]["type"]=="routes",timeout=40)
            # Reject first. No contact may be saved without the other side's consent.
            a.send(op="pair_request",address=b_addr,name="Alice")
            offer=b.wait("pair_offer")
            assert offer["peer"]==aid and offer["name"]=="Alice"
            b.send(op="pair_decline",id=offer["id"])
            assert not a.wait("pair_result")["ok"]
            for n in (a,b):
                n.send(op="contacts");assert n.wait("contacts")["contacts"]==[]
            # Accepted reciprocal contact.
            a.send(op="pair_request",address=b_addr,name="Alice")
            offer=b.wait("pair_offer")
            b.send(op="pair_accept",id=offer["id"],name="Bob")
            assert b.wait("pair_result")["ok"]
            assert a.wait("pair_result")["ok"]
            a.send(op="contacts");b.send(op="contacts")
            assert a.wait("contacts")["contacts"][0]["peer"]==bid
            assert b.wait("contacts")["contacts"][0]["peer"]==aid
            a.send(op="send",peer=bid,text="paired");msg=b.wait("message")
            assert msg["text"]=="paired" and msg["peer"]==aid
            assert a.wait("delivery")["ok"]
            # Restart a client: trusted settings and contacts persist.
            a.stop();nodes.remove(a)
            a=Node(binary,root/"alice");nodes.append(a)
            a.wait("network_state",lambda e:e["state"]=="ready",timeout=45)
            a.send(op="contacts");assert a.wait("contacts")["contacts"][0]["peer"]==bid
            a.send(op="send",peer=bid,text="after restart")
            assert b.wait("message")["text"]=="after restart"
            assert a.wait("delivery")["ok"]
            print("Automatic trusted bootstrap and relay, mutual pairing, persisted contacts/settings, chat after reconnect: PASS")
        finally:
            for node in reversed(nodes):node.stop()

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--binary",default="./target/debug/betelgeuse")
    run(os.path.abspath(p.parse_args().binary))
