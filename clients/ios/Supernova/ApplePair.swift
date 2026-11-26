import Foundation
import SwiftUI
import MultipeerConnectivity

struct ApplePairPeer: Identifiable {
    let id:String
    let name:String
    let peer:MCPeerID
}
struct ApplePairOffer: Identifiable {
    let id:String
    let peer:String
    let name:String
    let link:String
}

/// MultipeerConnectivity handles the nearby Apple transport (including
/// peer-to-peer Wi-Fi/Bluetooth as selected by iOS). Only signed, public
/// Rust invitations are exchanged after explicit user actions.
final class ApplePair: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    @Published private(set) var peers:[ApplePairPeer]=[]
    @Published private(set) var offer:ApplePairOffer?
    @Published private(set) var status=""
    var createInvite:((@escaping (String?)->Void)->Void)?
    var preview:((String,@escaping (String?,String?)->Void)->Void)?
    var importInvite:((String,String)->Void)?
    private var session:MCSession?
    private var advertiser:MCNearbyServiceAdvertiser?
    private var browser:MCNearbyServiceBrowser?
    private var own=""
    private var name=""
    private var target:MCPeerID?
    private var outgoing=false
    private var token=""
    private var sent=false
    private var received=false
    private var deadline:DispatchWorkItem?

    func start(peer:String,name:String) {
        guard !peer.isEmpty,peer.utf8.count<=63 else{return}
        if session != nil&&own==peer&&self.name==name{return}
        stop()
        own=peer;self.name=name
        let identity=MCPeerID(displayName:peer)
        let sess=MCSession(peer:identity,securityIdentity:nil,encryptionPreference:.required)
        sess.delegate=self;session=sess
        let adv=MCNearbyServiceAdvertiser(peer:identity,discoveryInfo:["peer":peer,"name":name],serviceType:"bgl-pair")
        adv.delegate=self;advertiser=adv;adv.startAdvertisingPeer()
        let br=MCNearbyServiceBrowser(peer:identity,serviceType:"bgl-pair")
        br.delegate=self;browser=br;br.startBrowsingForPeers()
    }

    func stop() {
        deadline?.cancel();deadline=nil
        advertiser?.stopAdvertisingPeer();advertiser?.delegate=nil;advertiser=nil
        browser?.stopBrowsingForPeers();browser?.delegate=nil;browser=nil
        session?.delegate=nil;session?.disconnect();session=nil
        peers.removeAll();offer=nil;target=nil;token="";sent=false;received=false
        status=""
    }

    func request(_ item:ApplePairPeer) {
        guard target==nil,let session,let browser else{return}
        outgoing=true;target=item.peer;token=UUID().uuidString.lowercased();sent=false;received=false
        status="Ожидаю соединения Apple…";setDeadline()
        browser.invitePeer(item.peer,to:session,withContext:nil,timeout:30)
    }

    func accept() {
        guard let item=offer, target != nil else{return}
        let expected=token
        status="Обмениваюсь подписанными профилями…"
        createInvite? { [weak self] link in
            guard let self,self.token==expected,self.offer?.id==item.id,let link else{return}
            self.importInvite?(item.link,item.peer)
            if self.send("accept",link:link){
                self.offer=nil;self.status="Контакт P2P добавлен"
                // Allow the accepted invitation to be delivered before closing.
                DispatchQueue.main.asyncAfter(deadline:.now()+2){[weak self] in if self?.token==expected {self?.finish("Контакт P2P добавлен")}}
            } else {self.finish("Ответ не доставлен")}
        }
    }
    func decline() {
        _=send("reject");finish("Запрос отклонён")
    }
    private func setDeadline() {
        deadline?.cancel()
        let work=DispatchWorkItem{[weak self] in self?.finish("Время ожидания истекло")}
        deadline=work;DispatchQueue.main.asyncAfter(deadline:.now()+75,execute:work)
    }
    @discardableResult private func send(_ kind:String,link:String?=nil)->Bool {
        guard let target,let session else{return false}
        var object:[String:Any]=["kind":kind,"id":token]
        if let link {object["link"]=link}
        guard let data=try? JSONSerialization.data(withJSONObject:object),data.count<=16_000 else{return false}
        do {try session.send(data,toPeers:[target],with:.reliable);return true}
        catch{return false}
    }
    private func finish(_ reason:String) {
        deadline?.cancel();deadline=nil;target=nil;token="";offer=nil;sent=false;received=false
        session?.disconnect()
        status=reason
    }

    func advertiser(_ advertiser:MCNearbyServiceAdvertiser,didReceiveInvitationFromPeer peerID:MCPeerID,withContext context:Data?,invitationHandler:@escaping(Bool,MCSession?)->Void) {
        DispatchQueue.main.async{[weak self] in
            guard let self,self.advertiser===advertiser,self.target==nil,let session=self.session, peerID.displayName != self.own else{
                invitationHandler(false,nil);return
            }
            // Accept the temporary encrypted transport, not the contact.
            self.target=peerID;self.outgoing=false;self.token="";self.sent=false;self.received=false;self.setDeadline()
            invitationHandler(true,session)
        }
    }
    func advertiser(_ advertiser:MCNearbyServiceAdvertiser,didNotStartAdvertisingPeer error:Error) {
        DispatchQueue.main.async{[weak self] in self?.status="Обнаружение Apple недоступно"}
    }
    func browser(_ browser:MCNearbyServiceBrowser,foundPeer peerID:MCPeerID,withDiscoveryInfo info:[String:String]?) {
        DispatchQueue.main.async{[weak self] in
            guard let self,self.browser===browser,let peer=info?["peer"],peer==peerID.displayName,peer != self.own,self.peers.count<32 else{return}
            let item=ApplePairPeer(id:peer,name:String((info?["name"] ?? "Бетельгейзе").prefix(40)),peer:peerID)
            self.peers.removeAll{$0.id==peer};self.peers.append(item)
        }
    }
    func browser(_ browser:MCNearbyServiceBrowser,lostPeer peerID:MCPeerID) {
        DispatchQueue.main.async{[weak self] in self?.peers.removeAll{$0.peer==peerID}}
    }
    func browser(_ browser:MCNearbyServiceBrowser,didNotStartBrowsingForPeers error:Error) {
        DispatchQueue.main.async{[weak self] in self?.status="Поиск Apple недоступен"}
    }
    func session(_ session:MCSession,peer peerID:MCPeerID,didChange state:MCSessionState) {
        DispatchQueue.main.async{[weak self] in
            guard let self,self.session===session,self.target==peerID else{return}
            if state == .connected,self.outgoing,!self.sent {
                let id=self.token;self.sent=true
                self.createInvite?{[weak self] link in
                    guard let self,self.token==id,let link else{return}
                    if self.send("offer",link:link){self.status="Ожидаю подтверждения"}
                    else{self.finish("Приглашение не доставлено")}
                }
            } else if state == .notConnected {self.finish("Соединение Apple завершено")}
        }
    }
    func session(_ session:MCSession,didReceive data:Data,fromPeer peerID:MCPeerID) {
        guard data.count<=16_000 else{return}
        DispatchQueue.main.async{[weak self] in
            guard let self,self.session===session,self.target==peerID,
                  let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let kind=object["kind"] as? String,let id=object["id"] as? String,
                  UUID(uuidString:id) != nil else{return}
            if kind=="reject",self.outgoing,id==self.token{self.finish("Запрос отклонён");return}
            guard let link=object["link"] as? String,link.utf8.count<=12_000,!self.received else{return}
            if kind=="offer",!self.outgoing,self.token.isEmpty {self.token=id}
            else if !(kind=="accept"&&self.outgoing&&id==self.token){return}
            self.received=true
            self.preview?(link){[weak self] verified,name in
                guard let self,self.token==id,self.target==peerID else{return}
                guard verified==peerID.displayName else{self.finish("Подпись профиля не подтверждена");return}
                if self.outgoing {
                    self.importInvite?(link,peerID.displayName);self.finish("Контакт P2P добавлен")
                }else{
                    self.offer=ApplePairOffer(id:id,peer:peerID.displayName,name:name ?? "Бетельгейзе",link:link)
                    self.status="Подтвердите добавление контакта"
                }
            }
        }
    }
    func session(_ session:MCSession,didReceive stream:InputStream,withName streamName:String,fromPeer peerID:MCPeerID){}
    func session(_ session:MCSession,didStartReceivingResourceWithName resourceName:String,fromPeer peerID:MCPeerID,with progress:Progress){}
    func session(_ session:MCSession,didFinishReceivingResourceWithName resourceName:String,fromPeer peerID:MCPeerID,at localURL:URL?,withError error:Error?){}
}
