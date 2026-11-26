"""Real application signaling and a multi-block file through authenticated peers."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
from two_nodes import Node, invoke

def run(binary, relay=False):
    with tempfile.TemporaryDirectory(prefix="bgl-exchange-") as tmp:
        root=Path(tmp)
        nodes=[]
        try:
            alice=invoke(binary,root/"alice","account","create")["peer"]
            bob=invoke(binary,root/"bob","account","create")["peer"]
            if relay:
                relay_id=invoke(binary,root/"relay","account","create")["peer"]
                r=Node(binary,root/"relay",relay_server=True);nodes.append(r)
                addr=r.wait("listen")["address"]
                r.send(op="announce",address=addr)
                r.wait("announced")
                a=Node(binary,root/"alice",addr);nodes.append(a)
                a.wait("connected",lambda e:e["peer"]==relay_id)
                a.wait("listen")
                a.send(op="reserve_relay",address=addr)
                route=a.wait("listen",lambda e:"/p2p-circuit/" in e["address"])["address"]
                a.wait("relay_reserved")
                b=Node(binary,root/"bob",addr);nodes.append(b)
                b.wait("connected",lambda e:e["peer"]==relay_id)
                b.wait("listen")
                a.send(op="invite",name="Alice",addresses=[route.rsplit("/p2p/",1)[0]])
            else:
                a=Node(binary,root/"alice");nodes.append(a)
                addr=a.wait("listen")["address"]
                b=Node(binary,root/"bob",addr);nodes.append(b)
                b.wait("listen")
                a.wait("connected",lambda e:e["peer"]==bob)
                a.send(op="invite",name="Alice")
            link=a.wait("invite")["link"]
            b.send(op="invite",name="Bob")
            b_link=b.wait("invite")["link"]
            a.send(op="import",link=b_link);a.wait("contact")
            b.send(op="import",link=link);b.wait("contact")
            if relay:
                b.send(op="connect",address=route)
                b.wait("connected",lambda e:e["peer"]==alice and e["route"]=="relay")
            # The media itself is tested separately with native WebRTC; verify
            # authenticated signaling routing and identity here.
            call="c6867129-c1eb-4d8d-8ee3-1f3ddd21cc01"
            b.send(op="call_signal",peer=alice,id=call,signal={"kind":"invite","video":True})
            event=a.wait("call_signal")
            assert event["peer"]==bob and event["id"]==call and event["signal"]["video"]
            a.send(op="call_signal",peer=bob,id=call,signal={"kind":"accept"})
            assert b.wait("call_signal")["signal"]["kind"]=="accept"
            b.send(op="call_signal",peer=alice,id=call,signal={"kind":"offer","sdp":"v=0\r\ns=Betelgeuse test\r\n"})
            assert a.wait("call_signal")["signal"]["kind"]=="offer"
            a.send(op="call_signal",peer=bob,id=call,signal={"kind":"ice","candidate":"candidate:test","mid":"0","line":0})
            assert b.wait("call_signal")["signal"]["kind"]=="ice"
            a.send(op="call_signal",peer=bob,id=call,signal={"kind":"hangup"})
            assert b.wait("call_signal")["signal"]["kind"]=="hangup"
            path=root/"sample.bin"
            payload=bytes(range(256))*8192
            path.write_bytes(payload)
            b.send(op="file_send",peer=alice,path=str(path),name="sample.bin")
            sent=b.wait("file_offered")
            offer=a.wait("file_offer")
            assert sent["id"]==offer["id"] and offer["size"]==len(payload)
            assert not list((root/"alice"/"transfers").glob("received-*"))
            a.send(op="file_accept",peer=bob,id=offer["id"])
            event=a.wait("file_received",timeout=90)
            assert Path(event["path"]).read_bytes()==payload
            assert event["digest"]==hashlib.sha256(payload).hexdigest()
            assert b.wait("file_delivered")["ok"]
            a.send(op="files")
            assert any(x["id"]==offer["id"] for x in a.wait("files")["files"])
            print(f"Signaling and SHA-256 file transfer ({'relay' if relay else 'direct'}): PASS")
        finally:
            for node in reversed(nodes): node.stop()

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--binary",default="./target/debug/betelgeuse")
    args=parser.parse_args()
    run(os.path.abspath(args.binary))
    run(os.path.abspath(args.binary),True)
