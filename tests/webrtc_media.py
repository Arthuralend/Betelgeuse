#!/usr/bin/env python3
"""Local, synthetic browser media acceptance. No real camera/mic or public service.

Two independent Rust CLI peers exchange actual SDP and ICE. Two WebRTC
connections exchange synthetic audio/video and must report received packets.
This does not exercise the mobile UIs or cellular networks.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import uuid

from two_nodes import Node, invoke

HTML = r"""<!doctype html><meta charset="utf-8"><title>Betelgeuse synthetic WebRTC test</title>
<script>
const run = async () => {
  let peers=[], streams=[];
  async function post(path, value) {
    const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});
    if(!r.ok) throw new Error(await r.text());
    return r.json();
  }
  try {
    const {ids,call}=await (await fetch('/config')).json();
    const send=(from,signal)=>post('/signal',{from,signal,id:call,peer:ids[1-from]});
    const delay=ms=>new Promise(r=>setTimeout(r,ms));
    const arrived=[[],[]], pending=[[],[]], sent=[false,false], local=[[],[]];
    for(let i=0;i<2;i++){
      const pc=new RTCPeerConnection({iceServers:[]});peers.push(pc);
      pc.ontrack=e=>arrived[i].push(e.track.kind);
      pc.onicecandidate=e=>{
        if(!e.candidate)return;
        const c=e.candidate;
        const data={kind:'ice',candidate:c.candidate,mid:c.sdpMid,line:c.sdpMLineIndex};
        if(sent[i]) send(i,data).catch(err=>console.error(err));else local[i].push(data);
      };
      const media=await navigator.mediaDevices.getUserMedia({video:{width:320,height:240,frameRate:15},audio:true});
      streams.push(media); for(const t of media.getTracks())pc.addTrack(t,media);
    }
    async function publish(i,kind,desc){
      await peers[i].setLocalDescription(desc);
      await send(i,{kind,sdp:desc.sdp});
      sent[i]=true;
      for(const c of local[i])await send(i,c);
    }
    async function remote(i,kind,sdp){
      await peers[i].setRemoteDescription({type:kind,sdp});
      for(const c of pending[i])await peers[i].addIceCandidate(c);pending[i]=[];
    }
    await send(0,{kind:'invite',video:true});
    let deadline=Date.now()+45000, connected=false;
    while(Date.now()<deadline){
      const events=await (await fetch('/events')).json();
      for(let i=0;i<2;i++){
        for(const e of events[i]){
          if(e.peer!==ids[1-i]||e.id!==call)throw Error('wrong peer or call ID');
          const s=e.signal,pc=peers[i];
          if(s.kind==='invite') await send(i,{kind:'accept'});
          else if(s.kind==='accept')await publish(i,'offer',await pc.createOffer());
          else if(s.kind==='offer'){await remote(i,'offer',s.sdp);await publish(i,'answer',await pc.createAnswer())}
          else if(s.kind==='answer')await remote(i,'answer',s.sdp);
          else if(s.kind==='ice'){
            const c={candidate:s.candidate,sdpMid:s.mid,sdpMLineIndex:s.line};
            if(pc.remoteDescription)await pc.addIceCandidate(c);else pending[i].push(c);
          }
        }
      }
      if(peers.every(p=>p.connectionState==='connected') && arrived.every(a=>a.includes('audio')&&a.includes('video'))){
        connected=true;break;
      }
      await delay(100);
    }
    if(!connected)throw Error('ICE/media track timeout: '+peers.map(p=>p.connectionState));
    let result;
    deadline=Date.now()+12000;
    while(Date.now()<deadline){
      result=[];
      for(const pc of peers){
        let a=0,v=0,frames=0;
        for(const s of (await pc.getStats()).values()){
          if(s.type!=='inbound-rtp')continue;
          if(s.kind==='audio')a+=s.packetsReceived||0;
          if(s.kind==='video'){v+=s.packetsReceived||0;frames+=s.framesDecoded||0}
        }
        result.push({audioPackets:a,videoPackets:v,framesDecoded:frames});
      }
      if(result.every(x=>x.audioPackets>0&&x.videoPackets>0&&x.framesDecoded>0))break;
      await delay(250);
    }
    if(!result.every(x=>x.audioPackets>0&&x.videoPackets>0&&x.framesDecoded>0))throw Error('No decoded bidirectional media: '+JSON.stringify(result));
    await send(0,{kind:'hangup'});
    await post('/result',{ok:true,result});
  } catch(e){await post('/result',{ok:false,error:String(e)})}
  finally{for(const p of peers)p.close();for(const s of streams)for(const t of s.getTracks())t.stop()}
};
run();
</script>"""

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--binary',default='./target/debug/betelgeuse')
    p.add_argument('--chrome',default=os.environ.get('CHROME') or shutil.which('google-chrome') or shutil.which('chromium') or '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    args=p.parse_args()
    binary=os.path.abspath(args.binary)
    with tempfile.TemporaryDirectory(prefix='bgl-media-') as tmp:
        root=Path(tmp);nodes=[];chrome=None;server=None
        try:
            ids=[invoke(binary,root/name,'account','create')['peer'] for name in ['alice','bob']]
            a=Node(binary,root/'alice');nodes.append(a)
            address=a.wait('listen')['address']
            b=Node(binary,root/'bob',address);nodes.append(b)
            b.wait('listen');a.wait('connected',lambda e:e['peer']==ids[1])
            for node,name in zip(nodes,['Alice','Bob']):node.send(op='invite',name=name)
            links=[n.wait('invite')['link'] for n in nodes]
            for i,node in enumerate(nodes):
                node.send(op='import',link=links[1-i]);node.wait('contact')
            call=str(uuid.uuid4())
            done=threading.Event();result={}
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self,*args): pass
                def reply(self,value,code=200,kind='application/json'):
                    raw=(json.dumps(value) if kind=='application/json' else value).encode()
                    self.send_response(code);self.send_header('Content-Type',kind)
                    self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
                def do_GET(self):
                    if self.path=='/':self.reply(HTML,kind='text/html')
                    elif self.path=='/config':self.reply({'ids':ids,'call':call})
                    elif self.path=='/events':
                        import queue
                        out=[[],[]]
                        for i,node in enumerate(nodes):
                            while True:
                                try:e=node.queue.get_nowait()
                                except queue.Empty:break
                                if e.get('event')=='call_signal':out[i].append(e)
                                if e.get('event')=='call_delivery' and not e.get('ok'):print('Delivery error',e)
                        self.reply(out)
                    else:self.reply({},404)
                def do_POST(self):
                    n=int(self.headers.get('Content-Length','0'))
                    if n>65536:self.reply({},413);return
                    data=json.loads(self.rfile.read(n))
                    if self.path=='/signal':
                        i=data['from']
                        if i not in (0,1) or data['id']!=call or data['peer']!=ids[1-i]:self.reply({},400);return
                        nodes[i].send(op='call_signal',peer=data['peer'],id=call,signal=data['signal'])
                        self.reply({'ok':True})
                    elif self.path=='/result':
                        result.update(data);self.reply({'ok':True});done.set()
                    else:self.reply({},404)
            server=http.server.HTTPServer(('127.0.0.1',0),Handler)
            threading.Thread(target=server.serve_forever,daemon=True).start()
            with (root/'chrome.log').open('wb') as log:
                chrome=subprocess.Popen([args.chrome,'--headless=new','--no-first-run','--no-default-browser-check','--disable-gpu',
                    '--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--disable-background-networking',
                    '--autoplay-policy=no-user-gesture-required','--user-data-dir='+str(root/'chrome'),
                    'http://127.0.0.1:'+str(server.server_port)+'/'],stdout=log,stderr=log)
                if not done.wait(75):raise AssertionError('Synthetic media test timed out')
            assert result.get('ok'),result
            print('WebRTC bidirectional audio packets and decoded video frames through real libp2p signaling: PASS',result)
        finally:
            if chrome:
                chrome.terminate()
                try:chrome.wait(timeout=10)
                except subprocess.TimeoutExpired:chrome.kill();chrome.wait()
            if server:server.shutdown();server.server_close()
            for node in reversed(nodes):node.stop()

if __name__=='__main__':main()
