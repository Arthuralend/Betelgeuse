package am.supernova.local;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.net.Uri;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.widget.Switch;
import java.util.HashSet;
import java.util.LinkedHashSet;
import android.database.Cursor;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.LinkedHashMap;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

public final class RustActivity extends Activity {
    private RustCore core;
    private boolean ready,foreground;
    private int tcpPort;
    private NearbyDiscovery nearby;
    private ConnectivityManager connectivity;
    private ConnectivityManager.NetworkCallback networkCallback;
    private Network lastNetwork;
    private Switch autoNetwork,nearbyEnabled;
    private LinearLayout nearbyPanel,advancedPanel;
    private TextView networkStatus,diagnostic;
    private Button restartButton;
    private final HashSet<String> knownContacts=new HashSet<>();
    private final LinkedHashMap<String,JSONObject> pairOffers=new LinkedHashMap<>();
    private String pairStatus="";
    private String lanAddress="";
    private boolean loadingPreferences;
    private RustRtc call;
    private EditText iceUrls,iceUser,icePassword;
    private LinearLayout callPanel, filePanel;
    private final LinkedHashMap<String,JSONObject> files=new LinkedHashMap<>();
    private final LinkedHashMap<String,File> outgoingFiles=new LinkedHashMap<>();
    private File pendingStaged, exportFile;
    private String pendingPeer="";
    private static final int PICK_FILE=721, EXPORT_FILE=722;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView status, identity;
    private EditText name, bootstrap, inviteInput, peerInput, draft;
    private LinearLayout contacts, messages, inviteActions, chat;
    private String ownID = "", chosen = "", invitation = "";
    private File qrFile;
    private final Runnable polling = new Runnable() {
        @Override public void run() {
            if (core == null) return;
            for (int i = 0; i < 32 && core != null; i++) {
                String text = core.poll();
                if (text == null) break;
                try { event(new JSONObject(text)); }
                catch (Exception error) { status.setText(error.getMessage()); }
            }
            if (core != null) handler.postDelayed(this, 120);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(0xff10111a);
        getWindow().setNavigationBarColor(0xff10111a);
        ScrollView scroll = new ScrollView(this);
        LinearLayout content = column();
        content.setBackgroundColor(0xff10111a);
        content.setPadding(dp(16), dp(16), dp(16), dp(24));
        scroll.addView(content);
        setContentView(scroll);
        TextView title = label("Бетельгейзе · P2P"); title.setTextSize(25); content.addView(title);
        status = label("Запуск ядра…");content.addView(status);
        networkStatus=label("Ожидание сети");content.addView(networkStatus);
        name=input(content,"Ваше имя");
        name.setText(getPreferences(MODE_PRIVATE).getString("name",""));
        button(content,"Сохранить имя",()->{remember();configure();discover();});
        autoNetwork=new Switch(this);autoNetwork.setText("Автоматическое подключение");autoNetwork.setChecked(getPreferences(MODE_PRIVATE).getBoolean("autoNetwork",true));content.addView(autoNetwork);
        nearbyEnabled=new Switch(this);nearbyEnabled.setText("Устройства рядом");nearbyEnabled.setChecked(getPreferences(MODE_PRIVATE).getBoolean("nearbyEnabled",true));content.addView(nearbyEnabled);
        autoNetwork.setOnCheckedChangeListener((v,checked)->{getPreferences(MODE_PRIVATE).edit().putBoolean("autoNetwork",checked).apply();configure();});
        nearbyEnabled.setOnCheckedChangeListener((v,checked)->{getPreferences(MODE_PRIVATE).edit().putBoolean("nearbyEnabled",checked).apply();discover();});
        restartButton=new Button(this);restartButton.setText("Запустить сеть");restartButton.setAllCaps(false);
        restartButton.setOnClickListener(v->startCore());content.addView(restartButton);
        nearbyPanel=column();content.addView(nearbyPanel);
        button(content,"Дополнительные настройки",()->advancedPanel.setVisibility(advancedPanel.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE));
        advancedPanel=column();advancedPanel.setVisibility(View.GONE);content.addView(advancedPanel);
        diagnostic=label("");advancedPanel.addView(diagnostic);
        identity=label("");identity.setTextIsSelectable(true);advancedPanel.addView(identity);
        button(advancedPanel,"Копировать Peer ID",()->copy(ownID));
        bootstrap=input(advancedPanel,"Добавить доверенный узел /p2p/…");
        bootstrap.setText(getPreferences(MODE_PRIVATE).getString("bootstrap",""));
        button(advancedPanel,"Сохранить дополнительный узел",()->{remember();configure();});
        button(advancedPanel,"Сбросить дополнительный узел",()->{bootstrap.setText("");remember();configure();});
        button(advancedPanel,"Обновить профиль и маршруты",()->{remember();configure();command("network_changed");});
        button(advancedPanel, "Создать приглашение", () -> {
            remember();
            qrFile = new File(getCacheDir(), "betelgeuse-" + UUID.randomUUID() + ".svg");
            command("invite", "name", profileName(), "qr_path", qrFile.getAbsolutePath());
        });
        inviteActions = column();
        button(inviteActions, "Копировать приглашение", () -> copy(invitation));
        button(inviteActions, "Поделиться приглашением", () -> {
            Intent share = new Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, invitation);
            startActivity(Intent.createChooser(share, "Betelgeuse"));
        });
        button(inviteActions, "Показать QR-код", this::showQR);
        inviteActions.setVisibility(View.GONE); advancedPanel.addView(inviteActions);
        inviteInput = input(advancedPanel, "Вставьте приглашение");
        button(advancedPanel, "Добавить контакт", () -> command("import", "link", str(inviteInput)));
        peerInput = input(advancedPanel, "Поиск по Peer ID");
        button(advancedPanel, "Найти в DHT", () -> command("get", "peer", str(peerInput)));
        content.addView(label("WebRTC"));
        iceUrls=input(content,"STUN/TURN URL (необязательно)");
        iceUrls.setText(getPreferences(MODE_PRIVATE).getString("iceUrls",""));
        iceUser=input(content,"TURN логин");
        icePassword=input(content,"TURN пароль");
        icePassword.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        callPanel=column();content.addView(callPanel);
        content.addView(label("Контакты"));
        contacts = column(); content.addView(contacts);
        chat = column();
        button(chat,"Аудиозвонок",()->dial(false));
        button(chat,"Видеозвонок",()->dial(true));
        button(chat,"Обновить маршрут контакта",()->command("get","peer",chosen,"kind","routes"));
        button(chat,"Отправить файл",this::pickFile);
        messages = column(); chat.addView(messages);
        draft = input(chat, "Сообщение");
        button(chat, "Отправить", () -> {
            if (chosen.isEmpty()) return;
            command("send", "peer", chosen, "text", str(draft)); draft.setText("");
        });
        button(chat, "Повторить отправку", () -> command("retry", "peer", chosen));
        chat.setVisibility(View.GONE); content.addView(chat);
        filePanel=column();content.addView(filePanel);
        call=new RustRtc(this,(peer,id,signal)->command("call_signal","peer",peer,"id",id,"signal",signal),this::renderCall);
        button(content, "Открыть совместимый режим 0.3", () -> startActivity(new Intent(this, MainActivity.class)));
        nearby=new NearbyDiscovery(this,this::renderNearby);
        startCore();
        connectivity=(ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE);
        networkCallback=new ConnectivityManager.NetworkCallback(){
            @Override public void onAvailable(Network network){handler.post(()->{
                boolean changed=lastNetwork!=null&&!lastNetwork.equals(network);lastNetwork=network;
                if(ready){command("network_changed","reset",changed);if(changed&&nearby!=null)nearby.stop();discover();}
            });}
            @Override public void onLost(Network network){handler.post(()->{if(ready){command("network_changed");discover();}});}
        };
        try{connectivity.registerDefaultNetworkCallback(networkCallback);}catch(RuntimeException ignored){}
    }

    private void startCore(){
        if(ready)return;
        handler.removeCallbacks(polling);
        if(core!=null){core.close();core=null;}
        status.setText("Запуск ядра…");restartButton.setEnabled(false);
        try{core=new RustCore(this);handler.post(polling);
            final RustCore started=core;
            handler.postDelayed(()->{
                if(ready||core!=started)return;
                handler.removeCallbacks(polling);core.close();core=null;
                status.setText("Ядро не ответило. Повторите запуск.");restartButton.setEnabled(true);
            },15000);
        }catch(Throwable error){status.setText("Ядро недоступно: "+error.getMessage());restartButton.setEnabled(true);}
    }

    private String cleanName(){
        String value=str(name);
        while(value.getBytes(StandardCharsets.UTF_8).length>120&&!value.isEmpty())value=value.substring(0,value.offsetByCodePoints(value.length(),-1));
        return value;
    }
    private Object profileName() { String value=cleanName(); return value.isEmpty() ? JSONObject.NULL : value; }

    private void configure(){
        if(!ready)return;
        try{
            LinkedHashSet<String> nodes=new LinkedHashSet<>();
            try(InputStream stream=getAssets().open("bootstrap-local.json")){
                byte[] bytes=new byte[8192];int count=stream.read(bytes);
                if(count>0){JSONArray values=new JSONObject(new String(bytes,0,count,StandardCharsets.UTF_8)).optJSONArray("nodes");
                    if(values!=null)for(int i=0;i<values.length()&&nodes.size()<8;i++)nodes.add(values.getString(i));}
            }catch(java.io.IOException ignored){}
            String custom=str(bootstrap);if(!custom.isEmpty()&&nodes.size()<8)nodes.add(custom);
            JSONObject settings=new JSONObject().put("enabled",autoNetwork.isChecked()).put("name",profileName()).put("addresses",new JSONArray(nodes));
            command("configure_network","settings",settings);
            if(nodes.isEmpty())networkStatus.setText("Нет настроенного интернет-узла");
        }catch(Exception error){diagnostic.setText(error.getMessage());}
    }

    private void discover(){
        if(nearby==null)return;
        if(!foreground||!ready||!nearbyEnabled.isChecked()){nearby.stop();return;}
        if(tcpPort>0)nearby.start(ownID,tcpPort,cleanName().isEmpty()?"Бетельгейзе":cleanName());
    }
    private void renderNearby(){
        if(nearbyPanel==null)return;
        nearbyPanel.removeAllViews();
        nearbyPanel.addView(label("Рядом"));
        if(nearbyEnabled.isChecked()){
            nearbyPanel.addView(label(nearby==null?"Ожидание сети":nearby.status));
            if(nearby!=null)for(NearbyDiscovery.Peer peer:nearby.peers()){
                if(knownContacts.contains(peer.id))continue;
                button(nearbyPanel,peer.name+" · Добавить",()->command("pair_request","address",peer.address,"name",profileName()));
            }
        }
        for(JSONObject offer:pairOffers.values()){
            String id=offer.optString("id"),peer=offer.optString("peer"),alias=offer.isNull("name")?"Бетельгейзе":offer.optString("name");
            LinearLayout row=column();row.addView(label(alias+" предлагает контакт · "+peer.substring(Math.max(0,peer.length()-12))));
            button(row,"Принять",()->command("pair_accept","id",id,"name",profileName()));
            button(row,"Отклонить",()->command("pair_decline","id",id));nearbyPanel.addView(row);
        }
        if(!pairStatus.isEmpty())nearbyPanel.addView(label(pairStatus));
    }
    private String str(EditText input) { return input.getText().toString().trim(); }
    private void remember() { getPreferences(MODE_PRIVATE).edit().putString("bootstrap", str(bootstrap)).putString("name", str(name)).apply(); }

    private boolean command(String op, Object... fields) {
        if (core == null) return false;
        try {
            JSONObject payload = new JSONObject().put("op", op);
            for (int i = 0; i < fields.length; i += 2) payload.put((String) fields[i], fields[i+1]);
            core.send(payload.toString());
            return true;
        } catch (Exception error) { status.setText(error.getMessage()); return false; }
    }

    private void refresh() { if (!chosen.isEmpty()) command("history", "peer", chosen); }

    private void event(JSONObject event) {
        switch (event.optString("event")) {
            case "started":
                ownID = event.optString("peer"); identity.setText(ownID); status.setText("Узел запущен");
                ready=true;restartButton.setVisibility(View.GONE);
                command("contacts");command("files");configure();discover();break;
            case "listen":
                int port=event.optInt("tcp_port",0);
                if(port>0&&tcpPort!=port){tcpPort=port;discover();}break;
            case "network_state":
                switch(event.optString("state")){
                    case "configured":networkStatus.setText(event.optInt("nodes")>0?"Автоматическое подключение…":"Локальный режим");break;
                    case "connected":networkStatus.setText("Узел доступен. Устанавливаю маршрут…");break;
                    case "ready":networkStatus.setText("Интернет P2P готов");break;
                    case "retrying":networkStatus.setText("Переподключение…");break;
                }break;
            case "pair_offer":pairOffers.put(event.optString("id"),event);renderNearby();break;
            case "pair_sent":pairStatus="Ожидаю подтверждения контакта…";renderNearby();break;
            case "pair_result":case "pair_expired":
                pairOffers.remove(event.optString("id"));
                pairStatus=event.optBoolean("ok")?"Контакт добавлен":"Запрос закрыт или недоступен";renderNearby();break;
            case "connected":
                status.setText("relay".equals(event.optString("route")) ? "Подключение через relay" : "Прямое подключение"); break;
            case "direct_upgrade":
                if (event.optBoolean("ok")) status.setText("Прямое P2P-соединение");
                break;
            case "relay_reserved":
                status.setText("Ретранслятор доступен"); break;
            case "error": case "fatal": case "connection_error":
                diagnostic.setText(event.optString("error","Ошибка сети"));
                if("fatal".equals(event.optString("event"))){
                    if(call!=null)call.hangup();ready=false;tcpPort=0;
                    if(nearby!=null)nearby.stop();
                    status.setText("Ошибка ядра: "+event.optString("error"));restartButton.setVisibility(View.VISIBLE);restartButton.setEnabled(true);
                    if(core!=null){core.close();core=null;}
                }else status.setText("Сетевая операция не завершена");
                break;
            case "call_signal": case "call_delivery":
                if(call!=null)call.receive(event,str(iceUrls),str(iceUser),str(icePassword));
                break;
            case "file_offer":case "file_offered":case "file_received":case "file_progress":case "file_paused":
            case "file_delivered":case "file_failed":case "file_cancelled":case "file_prepare_failed":case "file_action_failed":case "file_started":case "file_ack_failed":case "files":
                fileEvent(event);break;
            case "invite":
                invitation = event.optString("link"); inviteActions.setVisibility(View.VISIBLE); break;
            case "contact":
                inviteInput.setText(""); command("contacts"); break;
            case "contacts":
                contacts.removeAllViews(); knownContacts.clear();
                JSONArray list = event.optJSONArray("contacts");
                if (list != null) for (int i = 0; i < list.length(); i++) {
                    JSONObject item = list.optJSONObject(i);
                    if (item == null) continue;
                    String peer = item.optString("peer");knownContacts.add(peer);
                    String label = item.isNull("name") ? peer.substring(0, Math.min(12, peer.length())) : item.optString("name");
                    button(contacts, label, () -> { chosen = peer; chat.setVisibility(View.VISIBLE); messages.removeAllViews(); refresh(); });
                }
                renderNearby();break;
            case "queued": case "message": case "delivery":
                refresh(); break;
            case "history":
                if (!chosen.equals(event.optString("peer"))) break;
                messages.removeAllViews();
                JSONArray lines = event.optJSONArray("messages");
                if (lines != null) for (int i = 0; i < lines.length(); i++) {
                    JSONObject message = lines.optJSONObject(i);
                    if (message == null) continue;
                    boolean mine = message.optBoolean("mine");
                    TextView bubble = label((mine ? "Вы: " : "") + message.optString("text") +
                        (mine ? (message.optBoolean("delivered") ? "  ✓" : "  …") : ""));
                    bubble.setPadding(dp(8), dp(8), dp(8), dp(8)); messages.addView(bubble);
                }
                break;
            case "put":
                status.setText(event.optBoolean("ok") ? "Запись опубликована" : "Публикация не подтверждена"); break;
            case "get":
                if (!event.optBoolean("ok")) { status.setText("Запись не найдена"); break; }
                JSONObject data = event.optJSONObject("record");
                JSONObject body = data != null ? data.optJSONObject("body") : null;
                JSONObject payload = body != null ? body.optJSONObject("payload") : null;
                status.setText("Подписанная запись найдена" + (payload != null && !payload.isNull("name") ? ": " + payload.optString("name") : ""));
                break;
        }
    }

    private void dial(boolean video){
        if(call==null||chosen.isEmpty())return;
        String urls=str(iceUrls);
        getPreferences(MODE_PRIVATE).edit().putString("iceUrls",urls).apply();
        call.dial(chosen,video,urls,str(iceUser),str(icePassword));
    }

    private void renderCall(){
        if(callPanel==null||call==null)return;
        callPanel.removeAllViews();
        if(!call.status.isEmpty())callPanel.addView(label(call.status));
        if(!call.active())return;
        String who=call.peer;
        callPanel.addView(label(who.length()>18?who.substring(0,18)+"…":who));
        if(call.phase.equals("incoming"))button(callPanel,"Ответить",call::answer);
        if(call.remoteView!=null)callPanel.addView(call.remoteView,new LinearLayout.LayoutParams(-1,dp(230)));
        if(call.localView!=null)callPanel.addView(call.localView,new LinearLayout.LayoutParams(-1,dp(130)));
        if(call.phase.equals("connected")||call.phase.equals("connecting")){
            button(callPanel,call.muted?"Включить микрофон":"Выключить микрофон",call::toggleMute);
            if(call.video)button(callPanel,call.cameraDisabled?"Включить камеру":"Выключить камеру",call::toggleCamera);
        }
        button(callPanel,call.phase.equals("incoming")?"Отклонить":"Завершить",call::hangup);
    }

    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){
        super.onRequestPermissionsResult(request,permissions,results);
        if(request==RustRtc.PERMISSIONS&&call!=null)call.permissions(results);
    }

    private void pickFile(){
        if(chosen.isEmpty()||pendingStaged!=null)return;
        pendingPeer=chosen;
        Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);
        startActivityForResult(intent,PICK_FILE);
    }

    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(result!=RESULT_OK||data==null||data.getData()==null)return;
        Uri uri=data.getData();
        if(request==PICK_FILE)stage(uri,pendingPeer);
        if(request==EXPORT_FILE&&exportFile!=null){
            File source=exportFile;exportFile=null;
            new Thread(()->{
                try(InputStream in=new FileInputStream(source);OutputStream out=getContentResolver().openOutputStream(uri,"w")){
                    if(out==null)throw new java.io.IOException("Нет доступа к файлу");
                    copyStream(in,out);handler.post(()->status.setText("Файл сохранён"));
                }catch(Exception e){handler.post(()->status.setText(e.getMessage()));}
            },"file-export").start();
        }
    }

    private long copyStream(InputStream in,OutputStream out)throws java.io.IOException{
        byte[] buffer=new byte[64*1024];long total=0;int size;
        while((size=in.read(buffer))!=-1){
            total+=size;if(total>256L*1024*1024)throw new java.io.IOException("Максимальный размер файла 256 МБ");
            out.write(buffer,0,size);
        }
        return total;
    }

    private void stage(Uri uri,String peer){
        if(pendingStaged!=null||peer.isEmpty())return;
        File destination=new File(getCacheDir(),"betelgeuse-outgoing-"+UUID.randomUUID()+".bin");
        pendingStaged=destination;status.setText("Подготовка файла…");
        new Thread(()->{
            String fileName="file";
            try(Cursor c=getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){
                if(c!=null&&c.moveToFirst()&&c.getString(0)!=null)fileName=c.getString(0);
            }catch(Exception ignored){}
            try(InputStream in=getContentResolver().openInputStream(uri);OutputStream out=new FileOutputStream(destination)){
                if(in==null)throw new java.io.IOException("Нет доступа к файлу");
                copyStream(in,out);
                String selected=fileName;
                handler.post(()->{
                    if(core==null||pendingStaged!=destination){destination.delete();return;}
                    if(!command("file_send","peer",peer,"path",destination.getAbsolutePath(),"name",selected)){
                        pendingStaged=null;destination.delete();
                    }
                });
            }catch(Exception error){
                destination.delete();
                handler.post(()->{pendingStaged=null;status.setText(error.getMessage());});
            }
        },"file-stage").start();
    }

    private void fileEvent(JSONObject event){
        String kind=event.optString("event");
        if(kind.equals("file_prepare_failed")){
            if(pendingStaged!=null){pendingStaged.delete();pendingStaged=null;}
            status.setText(event.optString("error","Ошибка файла"));return;
        }
        if(kind.equals("file_action_failed")||kind.equals("file_ack_failed")){
            status.setText(event.optString("error","Ошибка файла"));return;
        }
        if(kind.equals("files")){
            JSONArray list=event.optJSONArray("files");
            if(list!=null)for(int i=0;i<list.length();i++){
                JSONObject item=list.optJSONObject(i);
                if(item!=null)try{item.put("event","file_received");fileEvent(item);}catch(Exception ignored){}
            }
            return;
        }
        String id=event.optString("id");if(id.isEmpty())return;
        JSONObject item=files.get(id);
        try{
            switch(kind){
                case "file_offer":case "file_offered":case "file_received":
                    item=new JSONObject(event.toString());
                    item.put("state",kind.equals("file_offer")?"offer":kind.equals("file_offered")?"sent_offer":"received");
                    files.put(id,item);
                    if(kind.equals("file_offered")&&pendingStaged!=null){outgoingFiles.put(id,pendingStaged);pendingStaged=null;}
                    break;
                case "file_started":if(item!=null)item.put("state","receiving");break;
                case "file_progress":
                    if(item!=null){item.put("received",event.optLong("received"));item.put("state",event.optBoolean("active",true)?"receiving":"paused");}
                    break;
                case "file_paused":if(item!=null)item.put("state","paused");break;
                case "file_delivered":case "file_failed":case "file_cancelled":
                    if(item!=null)item.put("state",kind.equals("file_delivered")?"delivered":kind.equals("file_failed")?"failed":"cancelled");
                    File staged=outgoingFiles.remove(id);if(staged!=null)staged.delete();
                    if(event.has("error"))status.setText(event.optString("error"));
                    break;
            }
        }catch(Exception ignored){}
        renderFiles();
    }

    private void fileAction(String action,JSONObject item){
        command("file_"+action,"peer",item.optString("peer"),"id",item.optString("id"));
    }

    private void renderFiles(){
        filePanel.removeAllViews();
        if(files.isEmpty())return;
        filePanel.addView(label("Файлы"));
        for(JSONObject item:files.values()){
            LinearLayout row=column();row.setPadding(0,dp(8),0,dp(8));
            row.addView(label(item.optString("name","Файл")+" · "+item.optLong("size")+" байт"));
            String state=item.optString("state");
            switch(state){
                case "offer":button(row,"Принять",()->fileAction("accept",item));button(row,"Отклонить",()->fileAction("cancel",item));break;
                case "receiving":case "paused":
                    row.addView(label(item.optLong("received")+" / "+item.optLong("size")));
                    button(row,state.equals("paused")?"Продолжить":"Пауза",()->fileAction(state.equals("paused")?"resume":"pause",item));
                    button(row,"Отмена",()->fileAction("cancel",item));break;
                case "sent_offer":row.addView(label("Ожидает получателя"));button(row,"Отмена",()->fileAction("cancel",item));break;
                case "received":
                    button(row,"Сохранить файл",()->{
                        exportFile=new File(item.optString("path"));
                        Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/octet-stream")
                            .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,item.optString("name"));
                        startActivityForResult(intent,EXPORT_FILE);
                    });break;
                case "delivered":row.addView(label("Доставлено"));break;
                case "cancelled":row.addView(label("Отменено"));break;
                default:row.addView(label("Ошибка передачи"));break;
            }
            filePanel.addView(row);
        }
    }

    private void showQR() {
        if (qrFile == null || !qrFile.isFile()) return;
        try (FileInputStream in = new FileInputStream(qrFile); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int count;
            while ((count = in.read(buffer)) != -1) bytes.write(buffer, 0, count);
            WebView web = new WebView(this);
            web.getSettings().setJavaScriptEnabled(false);
            web.getSettings().setAllowFileAccess(false);
            web.loadDataWithBaseURL(null, "<html><body style='margin:0'>" + new String(bytes.toByteArray(), StandardCharsets.UTF_8) + "</body></html>",
                "text/html", "UTF-8", null);
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Приглашение").setView(web).setPositiveButton("Закрыть", null).create();
            dialog.setOnDismissListener(d -> web.destroy()); dialog.show();
        } catch (Exception error) { status.setText(error.getMessage()); }
    }

    private void copy(String text) { getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Betelgeuse", text)); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private LinearLayout column() { LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); return l; }
    private TextView label(String text) { TextView v = new TextView(this); v.setTextColor(Color.WHITE); v.setText(text); v.setTextSize(15); return v; }
    private EditText input(LinearLayout parent, String hint) {
        EditText v = new EditText(this); v.setTextColor(Color.WHITE); v.setHintTextColor(0xffb4b4b4);
        v.setHint(hint); v.setSingleLine(true); parent.addView(v); return v;
    }
    private void button(LinearLayout parent, String text, Runnable action) {
        Button v = new Button(this); v.setText(text); v.setAllCaps(false);
        v.setTextColor(0xffc4c1ff); v.setOnClickListener(view -> action.run()); parent.addView(v);
    }

    @Override protected void onResume(){super.onResume();foreground=true;discover();if(ready)command("network_changed");}
    @Override protected void onPause(){foreground=false;if(nearby!=null)nearby.stop();super.onPause();}
    @Override protected void onDestroy() {
        handler.removeCallbacks(polling);
        if(nearby!=null)nearby.stop();
        if(connectivity!=null&&networkCallback!=null)try{connectivity.unregisterNetworkCallback(networkCallback);}catch(RuntimeException ignored){}
        if(call!=null)call.hangup();
        if (core != null) { core.close(); core = null; }
        if (qrFile != null) qrFile.delete();
        if(pendingStaged!=null){pendingStaged.delete();pendingStaged=null;}
        for(File file:outgoingFiles.values())file.delete();
        outgoingFiles.clear();
        super.onDestroy();
    }
}
