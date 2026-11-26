package am.supernova.local;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
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
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

public final class RustActivity extends Activity {
    private RustCore core;
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
        content.addView(label("Контакты"));
        contacts = column(); content.addView(contacts);
        chat = column();
        messages = column(); chat.addView(messages);
        draft = input(chat, "Сообщение");
        button(chat, "Отправить", () -> {
            if (chosen.isEmpty()) return;
            command("send", "peer", chosen, "text", str(draft)); draft.setText("");
        });
        button(chat, "Повторить отправку", () -> command("retry", "peer", chosen));
        chat.setVisibility(View.GONE); content.addView(chat);
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

    private void command(String op, Object... fields) {
        if (core == null) return;
        try {
            JSONObject payload = new JSONObject().put("op", op);
            for (int i = 0; i < fields.length; i += 2) payload.put((String) fields[i], fields[i+1]);
            core.send(payload.toString());
        } catch (Exception error) { status.setText(error.getMessage()); }
    }

    private void refresh() { if (!chosen.isEmpty()) command("history", "peer", chosen); }

    private void event(JSONObject event) {
        switch (event.optString("event")) {
            case "started":
                ownID = event.optString("peer"); identity.setText(ownID); status.setText("Узел запущен");
                command("contacts"); break;
            case "connected":
                status.setText("relay".equals(event.optString("route")) ? "Подключение через relay" : "Прямое подключение"); break;
            case "direct_upgrade":
                if (event.optBoolean("ok")) status.setText("Прямое P2P-соединение");
                break;
            case "relay_reserved":
                status.setText("Ретранслятор доступен"); break;
            case "error": case "fatal": case "connection_error":
                status.setText(event.optString("error", "Ошибка сети")); break;
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
        if (core != null) { core.close(); core = null; }
        if (qrFile != null) qrFile.delete();
        super.onDestroy();
    }
}
