package am.supernova.local;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;

/** DNS-SD discovery via Android's platform service. Advertisement metadata
 * is untrusted until the signed pair request is verified by Rust. */
final class NearbyDiscovery {
    static final class Peer {
        final String id,name,address;
        Peer(String id,String name,String address){this.id=id;this.name=name;this.address=address;}
    }
    private static final String TYPE="_betelgeuse._tcp.";
    private final NsdManager nsd;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final Runnable changed;
    private final LinkedHashMap<String,Peer> found=new LinkedHashMap<>();
    private final ArrayDeque<NsdServiceInfo> pending=new ArrayDeque<>();
    private NsdManager.RegistrationListener registration;
    private NsdManager.DiscoveryListener discovery;
    private boolean resolving;
    private int generation,port;
    private String own="",name="";
    String status="";

    NearbyDiscovery(Context context,Runnable changed){nsd=(NsdManager)context.getSystemService(Context.NSD_SERVICE);this.changed=changed;}
    List<Peer> peers(){return new ArrayList<>(found.values());}

    void start(String own,int port,String name){
        if(nsd==null||own.isEmpty()||port<=0||port>65535)return;
        if(registration!=null&&this.own.equals(own)&&this.port==port&&this.name.equals(name))return;
        stop();this.own=own;this.port=port;this.name=name;
        int expected=generation;
        NsdServiceInfo info=new NsdServiceInfo();
        info.setServiceName(own);info.setServiceType(TYPE);info.setPort(port);
        info.setAttribute("peer",own);info.setAttribute("name",name);
        registration=new NsdManager.RegistrationListener(){
            @Override public void onServiceRegistered(NsdServiceInfo service){}
            @Override public void onRegistrationFailed(NsdServiceInfo service,int error){main.post(()->{if(expected==generation){status="Публикация рядом недоступна";changed.run();}});}
            @Override public void onServiceUnregistered(NsdServiceInfo service){}
            @Override public void onUnregistrationFailed(NsdServiceInfo service,int error){}
        };
        discovery=new NsdManager.DiscoveryListener(){
            @Override public void onStartDiscoveryFailed(String type,int error){main.post(()->{if(expected==generation){status="Локальный поиск недоступен";changed.run();}});}
            @Override public void onStopDiscoveryFailed(String type,int error){}
            @Override public void onDiscoveryStarted(String type){}
            @Override public void onDiscoveryStopped(String type){}
            @Override public void onServiceFound(NsdServiceInfo service){
                main.post(()->{
                    if(expected!=generation||service.getServiceName().equals(own)||pending.size()>=32||found.size()>=32)return;
                    pending.add(service);resolveNext(expected);
                });
            }
            @Override public void onServiceLost(NsdServiceInfo service){
                main.post(()->{
                    if(expected!=generation)return;
                    pending.removeIf(s->s.getServiceName().equals(service.getServiceName()));
                    found.remove(service.getServiceName());changed.run();
                });
            }
        };
        try{nsd.registerService(info,NsdManager.PROTOCOL_DNS_SD,registration);nsd.discoverServices(TYPE,NsdManager.PROTOCOL_DNS_SD,discovery);status="Ищу устройства в локальной сети…";}
        catch(RuntimeException error){status="Локальный поиск недоступен";}
        changed.run();
    }
    private void resolveNext(int expected){
        if(expected!=generation||resolving||pending.isEmpty())return;
        NsdServiceInfo info=pending.remove();resolving=true;
        try{nsd.resolveService(info,new NsdManager.ResolveListener(){
            @Override public void onResolveFailed(NsdServiceInfo service,int error){main.post(()->complete(expected));}
            @Override public void onServiceResolved(NsdServiceInfo service){
                main.post(()->{
                    if(expected!=generation)return;
                    try {
                        byte[] raw=service.getAttributes().get("peer");
                        String peer=raw==null?"":new String(raw,StandardCharsets.UTF_8);
                        InetAddress address=service.getHost();
                        int p=service.getPort();
                        if(peer.equals(service.getServiceName())&&!peer.equals(own)&&peer.matches("[A-Za-z0-9]{40,64}")&&
                            address instanceof Inet4Address&&!address.isLoopbackAddress()&&!address.isAnyLocalAddress()&&p>0&&p<=65535){
                            byte[] label=service.getAttributes().get("name");
                            String title=label==null?"Бетельгейзе":new String(label,StandardCharsets.UTF_8);
                            if(title.length()>80)title=title.substring(0,80);
                            found.put(peer,new Peer(peer,title,"/ip4/"+address.getHostAddress()+"/tcp/"+p+"/p2p/"+peer));changed.run();
                        }
                    }finally{complete(expected);}
                });
            }
        });}catch(RuntimeException error){complete(expected);}
    }
    private void complete(int expected){
        if(expected!=generation)return;
        resolving=false;resolveNext(expected);
    }

    void stop(){
        generation++;resolving=false;pending.clear();found.clear();
        if(discovery!=null){try{nsd.stopServiceDiscovery(discovery);}catch(RuntimeException ignored){}discovery=null;}
        if(registration!=null){try{nsd.unregisterService(registration);}catch(RuntimeException ignored){}registration=null;}
        status="";changed.run();
    }
}
