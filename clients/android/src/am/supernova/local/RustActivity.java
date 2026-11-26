package am.supernova.local;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Chronometer;
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
    private Dialog callDialog;
    private LinearLayout callScreen;
    private final LinkedHashMap<String,String> contactNames=new LinkedHashMap<>();
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
    private LinearLayout contacts, messages, inviteActions, chat, landing;
    private ScrollView settingsPane, messageScroll, callsPane;
    private LinearLayout callsList, bottomNav;
    private TextView navChats,navCalls,navSettings;
    private TextView chatTitle;
    private EditText contactSearch;
    private String currentFilter="";
    private final LinkedHashMap<String,String> previews=new LinkedHashMap<>();
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
        LinearLayout screen=column();screen.setBackgroundColor(0xff10111a);setContentView(screen);
        settingsPane=scroll;screen.addView(settingsPane,new LinearLayout.LayoutParams(-1,0,1));settingsPane.setVisibility(View.GONE);
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
        button(advancedPanel,"Обновить маршрут выбранного контакта",()->{if(!chosen.isEmpty())command("get","peer",chosen,"kind","routes");});
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
        content.addView(label("Голосовой маршрут · STUN/TURN"));
        iceUrls=input(content,"STUN/TURN URL (необязательно)");
        iceUrls.setText(getPreferences(MODE_PRIVATE).getString("iceUrls",""));
        iceUser=input(content,"TURN логин");
        icePassword=input(content,"TURN пароль");
        icePassword.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        loadTurnCredentials();button(content,"Сохранить параметры звонков",this::saveTurnCredentials);
        filePanel=column();content.addView(filePanel);
        button(content, "Открыть совместимый режим 0.3", () -> startActivity(new Intent(this, MainActivity.class)));
        landing=column();landing.setPadding(dp(16),dp(12),dp(16),dp(12));screen.addView(landing,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout listHeader=new LinearLayout(this);listHeader.setGravity(Gravity.CENTER_VERTICAL);landing.addView(listHeader);
        TextView brand=label("Бетельгейзе");brand.setTextSize(26);brand.setTextColor(0xffffa855);listHeader.addView(brand,new LinearLayout.LayoutParams(0,-2,1));
        button(landing,"＋  Добавить контакт",()->{showSettings();advancedPanel.setVisibility(View.VISIBLE);});
        contactSearch=input(landing,"Поиск контактов");
        contactSearch.addTextChangedListener(new android.text.TextWatcher(){
            public void beforeTextChanged(CharSequence t,int a,int c,int f){}
            public void onTextChanged(CharSequence t,int a,int b,int c){currentFilter=t.toString();renderContacts();}
            public void afterTextChanged(android.text.Editable e){}
        });
        ScrollView contactScroll=new ScrollView(this);contacts=column();contactScroll.addView(contacts);landing.addView(contactScroll,new LinearLayout.LayoutParams(-1,0,1));
        chat=column();chat.setPadding(dp(10),dp(8),dp(10),dp(10));screen.addView(chat,new LinearLayout.LayoutParams(-1,0,1));chat.setVisibility(View.GONE);
        LinearLayout header=new LinearLayout(this);header.setGravity(Gravity.CENTER_VERTICAL);chat.addView(header);
        button(header,"‹",this::showChats);
        chatTitle=label("Переписка");chatTitle.setTextSize(20);header.addView(chatTitle,new LinearLayout.LayoutParams(0,-2,1));
        button(header,"☎",()->dial(false));button(header,"Видео",()->dial(true));
        Button more=new Button(this);more.setText("⋯");header.addView(more);more.setOnClickListener(v->{android.widget.PopupMenu menu=new android.widget.PopupMenu(this,v);menu.getMenu().add("Повторить отправку").setOnMenuItemClickListener(i->{command("retry","peer",chosen);return true;});menu.show();});
        callPanel=column();chat.addView(callPanel);
        messageScroll=new ScrollView(this);messages=column();messageScroll.addView(messages);chat.addView(messageScroll,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout composer=new LinearLayout(this);composer.setGravity(Gravity.CENTER_VERTICAL);chat.addView(composer);
        button(composer,"＋",this::pickFile);
        draft=new EditText(this);draft.setTextColor(Color.WHITE);draft.setHintTextColor(0xffb4b4b4);draft.setHint("Сообщение");draft.setMaxLines(5);composer.addView(draft,new LinearLayout.LayoutParams(0,-2,1));
        button(composer,"➤",()->{if(!chosen.isEmpty()&&!str(draft).trim().isEmpty()){command("send","peer",chosen,"text",str(draft));draft.setText("");}});
        callsPane=new ScrollView(this);callsList=column();callsList.setPadding(dp(16),dp(12),dp(16),dp(12));callsPane.addView(callsList);screen.addView(callsPane,new LinearLayout.LayoutParams(-1,0,1));callsPane.setVisibility(View.GONE);
        bottomNav=new LinearLayout(this);bottomNav.setBackgroundColor(0xff21191b);screen.addView(bottomNav,new LinearLayout.LayoutParams(-1,dp(67)));
        navChats=navItem("◉\nЧаты",this::showChats);navCalls=navItem("☎\nЗвонки",this::showCalls);navSettings=navItem("⚙\nНастройки",this::showSettings);markNav(navChats);
        call=new RustRtc(this,(peer,id,signal)->command("call_signal","peer",peer,"id",id,"signal",signal),this::renderCall);
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
                contacts.removeAllViews(); knownContacts.clear();contactNames.clear();
                JSONArray list = event.optJSONArray("contacts");
                if (list != null) for (int i = 0; i < list.length(); i++) {
                    JSONObject item = list.optJSONObject(i);
                    if (item == null) continue;
                    String peer = item.optString("peer");knownContacts.add(peer);
                    String label = item.isNull("name") ? peer.substring(0, Math.min(12, peer.length())) : item.optString("name");
                    contactNames.put(peer,label);

                }
                renderContacts();renderCalls();renderNearby();int counted=0;for(String contact:contactNames.keySet()){if(counted++>=30)break;command("history","peer",contact);}break;
            case "queued": case "message": case "delivery":
                String changedPeer=event.optString("peer");if(!changedPeer.isEmpty()&&!changedPeer.equals(chosen))command("history","peer",changedPeer);else refresh();break;
            case "history":
                String historyPeer=event.optString("peer");JSONArray lines=event.optJSONArray("messages");
                if(lines!=null&&lines.length()>0){JSONObject last=lines.optJSONObject(lines.length()-1);if(last!=null){previews.put(historyPeer,(last.optBoolean("mine")?"Вы: ":"")+last.optString("text"));renderContacts();}}
                if (!chosen.equals(historyPeer)) break;
                messages.removeAllViews();
                if (lines != null) for (int i = 0; i < lines.length(); i++) {
                    JSONObject message = lines.optJSONObject(i);
                    if (message == null) continue;
                    boolean mine = message.optBoolean("mine");
                    TextView bubble=label(message.optString("text")+(mine?(message.optBoolean("delivered")?"  ✓":"  …"):""));
                    bubble.setPadding(dp(12),dp(10),dp(12),dp(10));bubble.setMaxWidth(getResources().getDisplayMetrics().widthPixels*3/4);
                    GradientDrawable bg=new GradientDrawable();bg.setColor(mine?0xff543522:0xff292a34);bg.setCornerRadius(dp(17));bubble.setBackground(bg);
                    LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-2,-2);lp.gravity=mine?Gravity.END:Gravity.START;lp.setMargins(dp(8),dp(5),dp(8),dp(5));messages.addView(bubble,lp);
                }
                messageScroll.post(()->messageScroll.fullScroll(View.FOCUS_DOWN));break;
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

    private TextView navItem(String title,Runnable action){TextView v=label(title);v.setGravity(Gravity.CENTER);v.setTextSize(15);v.setOnClickListener(x->action.run());bottomNav.addView(v,new LinearLayout.LayoutParams(0,-1,1));return v;}
    private void markNav(TextView selected){for(TextView v:new TextView[]{navChats,navCalls,navSettings})if(v!=null)v.setTextColor(v==selected?0xffffa855:0xffa8a5ad);}
    private void showChats(){settingsPane.setVisibility(View.GONE);chat.setVisibility(View.GONE);callsPane.setVisibility(View.GONE);landing.setVisibility(View.VISIBLE);bottomNav.setVisibility(View.VISIBLE);markNav(navChats);}
    private void showSettings(){landing.setVisibility(View.GONE);chat.setVisibility(View.GONE);callsPane.setVisibility(View.GONE);settingsPane.setVisibility(View.VISIBLE);bottomNav.setVisibility(View.VISIBLE);markNav(navSettings);}
    private void showCalls(){landing.setVisibility(View.GONE);chat.setVisibility(View.GONE);settingsPane.setVisibility(View.GONE);callsPane.setVisibility(View.VISIBLE);bottomNav.setVisibility(View.VISIBLE);markNav(navCalls);renderCalls();}
    private void openChat(String peer){chosen=peer;chatTitle.setText(contactNames.containsKey(peer)?contactNames.get(peer):peer);landing.setVisibility(View.GONE);settingsPane.setVisibility(View.GONE);chat.setVisibility(View.VISIBLE);callsPane.setVisibility(View.GONE);bottomNav.setVisibility(View.GONE);messages.removeAllViews();draft.setText("");refresh();}
    private void renderContacts(){
        if(contacts==null)return;contacts.removeAllViews();
        for(java.util.Map.Entry<String,String> item:contactNames.entrySet()){
            String title=item.getValue(),peer=item.getKey();
            if(!title.toLowerCase(java.util.Locale.ROOT).contains(currentFilter.toLowerCase(java.util.Locale.ROOT)))continue;
            LinearLayout row=new LinearLayout(this);row.setGravity(Gravity.CENTER_VERTICAL);row.setPadding(dp(6),dp(12),dp(6),dp(12));
            TextView avatar=callText(title.isEmpty()?"✦":title.substring(0,1).toUpperCase(java.util.Locale.ROOT),22,0xffffa855);
            GradientDrawable bg=new GradientDrawable();bg.setColor(0xff3f2424);bg.setShape(GradientDrawable.OVAL);avatar.setBackground(bg);row.addView(avatar,new LinearLayout.LayoutParams(dp(52),dp(52)));
            LinearLayout names=column();names.setPadding(dp(14),0,0,0);TextView primary=label(title);primary.setTextSize(18);names.addView(primary);TextView sub=label(previews.containsKey(peer)?previews.get(peer):"Открыть переписку");sub.setSingleLine(true);sub.setEllipsize(android.text.TextUtils.TruncateAt.END);sub.setTextColor(0xffa8a5ad);sub.setTextSize(13);names.addView(sub);row.addView(names,new LinearLayout.LayoutParams(0,-2,1));
            row.setOnClickListener(v->openChat(peer));contacts.addView(row);View divider=new View(this);divider.setBackgroundColor(0xff32323a);contacts.addView(divider,new LinearLayout.LayoutParams(-1,dp(1)));
        }
        if(contactNames.isEmpty())contacts.addView(label("Нет контактов. Нажмите «Добавить контакт»."));
    }
    @Override public void onBackPressed(){if(chat.getVisibility()==View.VISIBLE||settingsPane.getVisibility()==View.VISIBLE||callsPane.getVisibility()==View.VISIBLE){showChats();return;}super.onBackPressed();}

    private void renderCalls(){
        if(callsList==null||call==null)return;callsList.removeAllViews();
        TextView title=label("Звонки");title.setTextSize(26);title.setTextColor(0xffffa855);callsList.addView(title);
        callsList.addView(label("Новый звонок"));
        for(java.util.Map.Entry<String,String> item:contactNames.entrySet()){
            String target=item.getKey();
            LinearLayout row=new LinearLayout(this);row.setGravity(Gravity.CENTER_VERTICAL);TextView who=label(item.getValue());who.setTextSize(17);row.addView(who,new LinearLayout.LayoutParams(0,-2,1));
            button(row,"☎",()->dialTo(target,false));button(row,"Видео",()->dialTo(target,true));callsList.addView(row);
        }
        callsList.addView(label("Недавние"));
        JSONArray history=call.history();
        if(history.length()==0)callsList.addView(label("История звонков пока пуста"));
        for(int i=0;i<history.length();i++){
            JSONObject item=history.optJSONObject(i);if(item==null)continue;String target=item.optString("peer");boolean video=item.optBoolean("video");String who=contactNames.containsKey(target)?contactNames.get(target):target.substring(0,Math.min(16,target.length()));
            LinearLayout row=new LinearLayout(this);row.setGravity(Gravity.CENTER_VERTICAL);row.setPadding(0,dp(10),0,dp(10));
            LinearLayout details=column();TextView primary=label((item.optBoolean("outgoing")?"↗  ":"↙  ")+who);primary.setTextSize(18);details.addView(primary);
            String date=java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT,java.text.DateFormat.SHORT).format(new java.util.Date(item.optLong("date")));
            TextView subtitle=label((video?"Видео · ":"Аудио · ")+item.optString("result")+" · "+date);subtitle.setTextColor(0xffa8a5ad);subtitle.setTextSize(12);details.addView(subtitle);row.addView(details,new LinearLayout.LayoutParams(0,-2,1));button(row,"☎",()->dialTo(target,video));callsList.addView(row);
        }
        if(history.length()>0)button(callsList,"Очистить историю",()->new AlertDialog.Builder(this).setMessage("Удалить историю звонков?").setNegativeButton("Отмена",null).setPositiveButton("Удалить",(d,w)->call.clearHistory()).show());
    }
    private javax.crypto.SecretKey turnKey() throws Exception{
        java.security.KeyStore ks=java.security.KeyStore.getInstance("AndroidKeyStore");ks.load(null);
        java.security.Key existing=ks.getKey("betelgeuse-turn-v1",null);if(existing instanceof javax.crypto.SecretKey)return (javax.crypto.SecretKey)existing;
        javax.crypto.KeyGenerator gen=javax.crypto.KeyGenerator.getInstance("AES","AndroidKeyStore");
        gen.init(new android.security.keystore.KeyGenParameterSpec.Builder("betelgeuse-turn-v1",android.security.keystore.KeyProperties.PURPOSE_ENCRYPT|android.security.keystore.KeyProperties.PURPOSE_DECRYPT).setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE).build());return gen.generateKey();
    }
    private void loadTurnCredentials(){
        try{String stored=getPreferences(MODE_PRIVATE).getString("turnCredentials","");if(stored.isEmpty())return;String[] parts=stored.split(":",2);if(parts.length!=2)return;
            javax.crypto.Cipher c=javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");c.init(javax.crypto.Cipher.DECRYPT_MODE,turnKey(),new javax.crypto.spec.GCMParameterSpec(128,android.util.Base64.decode(parts[0],android.util.Base64.NO_WRAP)));
            JSONArray values=new JSONArray(new String(c.doFinal(android.util.Base64.decode(parts[1],android.util.Base64.NO_WRAP)),StandardCharsets.UTF_8));iceUser.setText(values.optString(0));icePassword.setText(values.optString(1));
        }catch(Exception ignored){}
    }
    private void saveTurnCredentials(){
        try{javax.crypto.Cipher c=javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");c.init(javax.crypto.Cipher.ENCRYPT_MODE,turnKey());
            byte[] encrypted=c.doFinal(new JSONArray().put(str(iceUser)).put(str(icePassword)).toString().getBytes(StandardCharsets.UTF_8));
            getPreferences(MODE_PRIVATE).edit().putString("iceUrls",str(iceUrls)).putString("turnCredentials",android.util.Base64.encodeToString(c.getIV(),android.util.Base64.NO_WRAP)+":"+android.util.Base64.encodeToString(encrypted,android.util.Base64.NO_WRAP)).apply();
            android.widget.Toast.makeText(this,"Параметры сохранены",android.widget.Toast.LENGTH_SHORT).show();
        }catch(Exception e){android.widget.Toast.makeText(this,"Не удалось сохранить параметры",android.widget.Toast.LENGTH_SHORT).show();}
    }
    private void dial(boolean video){dialTo(chosen,video);}
    private void dialTo(String target,boolean video){
        if(call==null||target.isEmpty()||!ready)return;
        String urls=str(iceUrls);
        getPreferences(MODE_PRIVATE).edit().putString("iceUrls",urls).apply();
        call.dial(target,video,urls,str(iceUser),str(icePassword));
    }

    private void renderCall(){
        if(callPanel==null||call==null)return;
        callPanel.removeAllViews();
        if(!call.status.isEmpty())callPanel.addView(label(call.status));
        if(!call.active()){
            renderCalls();
            if(callDialog!=null){callDialog.dismiss();callDialog=null;callScreen=null;}
            return;
        }
        if(isFinishing()||isDestroyed())return;
        if(callDialog==null){
            callDialog=new Dialog(this,android.R.style.Theme_Material_NoActionBar_Fullscreen);
            callDialog.setCancelable(false);
            callScreen=column();callScreen.setPadding(dp(20),dp(24),dp(20),dp(24));
            callScreen.setGravity(Gravity.CENTER_HORIZONTAL);
            callScreen.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,new int[]{0xff361820,0xff09080c}));
            callDialog.setContentView(callScreen);
            callDialog.show();
            if(callDialog.getWindow()!=null)callDialog.getWindow().setLayout(-1,-1);
        }
        callScreen.removeAllViews();
        callScreen.addView(callText("БЕТЕЛЬГЕЙЗЕ",17,0xffffa855));
        View top=new View(this);callScreen.addView(top,new LinearLayout.LayoutParams(1,0,1));
        String who=contactNames.get(call.peer);
        if(who==null||who.isEmpty())who=call.peer.substring(0,Math.min(16,call.peer.length()));
        if(call.remoteView==null){
            TextView avatar=callText(call.video?"◉":"✦",52,0xffffa855);
            GradientDrawable bg=new GradientDrawable();bg.setColor(0xff3f2424);bg.setShape(GradientDrawable.OVAL);bg.setStroke(dp(2),0xffd7833c);avatar.setBackground(bg);
            callScreen.addView(avatar,new LinearLayout.LayoutParams(dp(116),dp(116)));
        }
        callScreen.addView(callText(who,29,Color.WHITE));
        callScreen.addView(callText(call.status,16,0xffc9c4cb));
        if(call.connectedAt>0&&call.phase.equals("connected")){
            Chronometer timer=new Chronometer(this);timer.setBase(call.connectedAt);timer.setTextColor(Color.WHITE);timer.setGravity(Gravity.CENTER);timer.start();callScreen.addView(timer);
        }
        if(call.remoteView!=null)attachCallVideo(call.remoteView,dp(220));
        if(call.localView!=null)attachCallVideo(call.localView,dp(110));
        View bottom=new View(this);callScreen.addView(bottom,new LinearLayout.LayoutParams(1,0,1));
        LinearLayout actions=new LinearLayout(this);actions.setGravity(Gravity.CENTER);callScreen.addView(actions);
        if(call.phase.equals("incoming")){
            callAction(actions,"Отклонить",0xffbd3640,call::hangup);
            callAction(actions,"Ответить",0xff18834d,call::answer);
        }else{
            if(call.phase.equals("connected")||call.phase.equals("connecting")){
                callAction(actions,call.muted?"Микр. выкл.":"Микрофон",0xff444047,call::toggleMute);
                if(call.phase.equals("connected"))callAction(actions,call.speaker?"Динамик вкл.":"Динамик",0xff444047,call::toggleSpeaker);
                if(call.video)callAction(actions,call.cameraDisabled?"Камера выкл.":"Камера",0xff444047,call::toggleCamera);
            }
            LinearLayout end=new LinearLayout(this);end.setGravity(Gravity.CENTER);callScreen.addView(end);
            callAction(end,"Завершить",0xffbd3640,call::hangup);
        }
    }

    private TextView callText(String value,int size,int color){
        TextView v=new TextView(this);v.setText(value);v.setTextSize(size);v.setTextColor(color);v.setGravity(Gravity.CENTER);v.setPadding(dp(4),dp(8),dp(4),dp(8));return v;
    }
    private void attachCallVideo(View v,int height){
        if(v.getParent() instanceof ViewGroup)((ViewGroup)v.getParent()).removeView(v);
        callScreen.addView(v,new LinearLayout.LayoutParams(-1,height));
    }
    private void callAction(LinearLayout row,String title,int color,Runnable action){
        Button b=new Button(this);b.setText(title);b.setAllCaps(false);b.setTextColor(Color.WHITE);b.setTextSize(13);
        GradientDrawable bg=new GradientDrawable();bg.setColor(color);bg.setCornerRadius(dp(26));b.setBackground(bg);
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,dp(58),1);lp.setMargins(dp(4),dp(8),dp(4),dp(8));row.addView(b,lp);b.setOnClickListener(v->action.run());
        row.getLayoutParams().width=-1;
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
        v.setTextColor(0xffffa855); v.setOnClickListener(view -> action.run()); parent.addView(v);
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
