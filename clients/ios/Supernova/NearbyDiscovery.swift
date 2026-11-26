import Foundation
import SwiftUI
import Network
import Darwin

struct LANPeer: Identifiable {
    let id: String
    let name: String
    let address: String
}

/// Platform DNS-SD publication of the existing Rust TCP listener. No extra
/// network listener is opened and discovery metadata is only a hint.
final class NearbyDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var peers: [LANPeer] = []
    @Published private(set) var status = ""
    private var service: NetService?
    private var browser: NetServiceBrowser?
    private var services: [String:NetService] = [:]
    private var own = ""
    private var port = 0
    private var name = ""
    private let type = "_betelgeuse._tcp."

    func start(peer: String, port: Int, name: String) {
        guard !peer.isEmpty, (1...65535).contains(port) else { return }
        if service != nil && own == peer && self.port == port && self.name == name { return }
        stop()
        own = peer; self.port = port; self.name = name
        let published = NetService(domain:"local.",type:type,name:peer,port:Int32(port))
        let record:[String:Data] = ["peer":Data(peer.utf8),"name":Data(name.utf8)]
        published.setTXTRecord(NetService.data(fromTXTRecord:record))
        published.delegate = self
        published.publish()
        service=published
        let search=NetServiceBrowser(); search.delegate=self
        browser=search; search.searchForServices(ofType:type,inDomain:"local.")
        status = "Ищу устройства в локальной сети…"
    }

    func stop() {
        browser?.stop();browser?.delegate=nil;browser=nil
        service?.stop();service?.delegate=nil;service=nil
        for item in services.values {item.stop();item.delegate=nil}
        services.removeAll();peers.removeAll();status=""
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,didFind service:NetService,moreComing:Bool) {
        guard browser === self.browser,service.name != own,services.count < 32,services[service.name] == nil else{return}
        services[service.name]=service;service.delegate=self
        service.resolve(withTimeout:8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,didRemove service:NetService,moreComing:Bool) {
        guard browser === self.browser else{return}
        if let old=services.removeValue(forKey:service.name){old.stop();old.delegate=nil}
        peers.removeAll{$0.id==service.name}
    }

    func netServiceBrowser(_ browser:NetServiceBrowser,didNotSearch errorDict:[String:NSNumber]) {
        guard browser === self.browser else{return}
        status="Локальный поиск недоступен. Проверьте разрешение локальной сети."
    }

    func netServiceDidResolveAddress(_ sender:NetService) {
        guard services[sender.name] === sender, sender.port>0, sender.port<=65535,
              let txtData=sender.txtRecordData() else{return}
        let txt=NetService.dictionary(fromTXTRecord:txtData)
        guard let peerData=txt["peer"],let peer=String(data:peerData,encoding:.utf8),peer==sender.name,peer != own,
              peer.count>=40,peer.count<=64,peer.utf8.allSatisfy({($0>=48&&$0<=57)||($0>=65&&$0<=90)||($0>=97&&$0<=122)}) else{return}
        let name=txt["name"].flatMap{String(data:$0,encoding:.utf8)} ?? ""
        for bytes in sender.addresses ?? [] {
            var address=sockaddr_in()
            guard bytes.count>=MemoryLayout<sockaddr_in>.size else{continue}
            withUnsafeMutableBytes(of:&address){dest in _=bytes.copyBytes(to:dest)}
            guard Int32(address.sin_family)==AF_INET else{continue}
            var host=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET,&address.sin_addr,&host,socklen_t(host.count)) != nil else{continue}
            let ip=String(cString:host)
            guard !ip.hasPrefix("127."),ip != "0.0.0.0" else{continue}
            let item=LANPeer(id:peer,name:name.isEmpty ? "Бетельгейзе" : String(name.prefix(40)),address:"/ip4/\(ip)/tcp/\(sender.port)/p2p/\(peer)")
            peers.removeAll{$0.id==peer};peers.append(item);return
        }
    }

    func netService(_ sender:NetService,didNotResolve errorDict:[String:NSNumber]) {
        if services[sender.name] === sender {services.removeValue(forKey:sender.name);sender.delegate=nil}
    }

    func netService(_ sender:NetService,didNotPublish errorDict:[String:NSNumber]) {
        if sender === service {status="Публикация в локальной сети недоступна"}
    }
}
