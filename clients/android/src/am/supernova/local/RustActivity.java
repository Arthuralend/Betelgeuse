package am.supernova.local;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.net.Uri;
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
            for (int i = 0; i < 32; i++) {
                String text = core.poll();
                if (text == null) break;
                try { event(new JSONObject(text)); }
                catch (Exception error) { status.setText(error.getMessage()); }
            }
            handler.postDelayed(this, 120);
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
        status = label("Запуск ядра…"); content.addView(status);
        identity = label(""); identity.setTextIsSelectable(true); content.addView(identity);
        button(content, "Копировать Peer ID", () -> copy(ownID));
        name = input(content, "Имя профиля");
        bootstrap = input(content, "Адрес узла /p2p/…");
        bootstrap.setText(getPreferences(MODE_PRIVATE).getString("bootstrap", ""));
        name.setText(getPreferences(MODE_PRIVATE).getString("name", ""));
        button(content, "Подключить узел", () -> {
            remember(); command("connect", "address", str(bootstrap));
        });
        button(content, "Резервировать relay", () -> {
            remember(); command("reserve_relay", "address", str(bootstrap));
        });
        button(content, "Опубликовать профиль и маршруты", () -> {
            remember(); command("put", "name", profileName()); command("publish_routes");
        });
        button(content, "Создать приглашение", () -> {
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
        inviteActions.setVisibility(View.GONE); content.addView(inviteActions);
        inviteInput = input(content, "Вставьте приглашение");
        button(content, "Добавить контакт", () -> command("import", "link", str(inviteInput)));
        peerInput = input(content, "Поиск по Peer ID");
        button(content, "Найти в DHT", () -> command("get", "peer", str(peerInput)));
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
        try {
            core = new RustCore(this);
            handler.post(polling);
        } catch (Throwable error) {
            status.setText("Ядро недоступно: " + error.getMessage());
        }
    }

    private Object profileName() { String value = str(name); return value.isEmpty() ? JSONObject.NULL : value; }
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
                command("contacts"); command("files"); break;
            case "connected":
                status.setText("relay".equals(event.optString("route")) ? "Подключение через relay" : "Прямое подключение"); break;
            case "direct_upgrade":
                if (event.optBoolean("ok")) status.setText("Прямое P2P-соединение");
                break;
            case "relay_reserved":
                status.setText("Ретранслятор доступен"); break;
            case "error": case "fatal": case "connection_error":
                status.setText(event.optString("error", "Ошибка сети"));
                if("fatal".equals(event.optString("event"))&&call!=null)call.hangup();
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
                contacts.removeAllViews();
                JSONArray list = event.optJSONArray("contacts");
                if (list != null) for (int i = 0; i < list.length(); i++) {
                    JSONObject item = list.optJSONObject(i);
                    if (item == null) continue;
                    String peer = item.optString("peer");
                    String label = item.isNull("name") ? peer.substring(0, Math.min(12, peer.length())) : item.optString("name");
                    button(contacts, label, () -> { chosen = peer; chat.setVisibility(View.VISIBLE); messages.removeAllViews(); refresh(); });
                }
                break;
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

    @Override protected void onDestroy() {
        handler.removeCallbacks(polling);
        if(call!=null)call.hangup();
        if (core != null) { core.close(); core = null; }
        if (qrFile != null) qrFile.delete();
        if(pendingStaged!=null){pendingStaged.delete();pendingStaged=null;}
        for(File file:outgoingFiles.values())file.delete();
        outgoingFiles.clear();
        super.onDestroy();
    }
}
