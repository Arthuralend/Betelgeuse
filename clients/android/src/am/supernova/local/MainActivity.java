package am.supernova.local;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

public final class MainActivity extends Activity {
    private static final int PICK = 1, SAVE = 2, MICROPHONE = 3;
    private static final int BACKGROUND = 0xff10111a, PANEL = 0xff1c2031, OUTGOING = 0xff373167, ACCENT = 0xffc4c1ff;
    private DirectSession session;
    private LinearLayout connect, actions, messages, contacts;
    private EditText name, invite, draft;
    private TextView status, peer;
    private ScrollView transcript;
    private Button send;
    private File fileToSave;
    private boolean answeringAfterPermission;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(BACKGROUND);
        getWindow().setNavigationBarColor(BACKGROUND);
        session = new DirectSession(this, this::render);
        LinearLayout layout = column();
        layout.setBackgroundColor(BACKGROUND);
        layout.setPadding(px(18), px(16), px(18), px(10));
        setContentView(layout);

        TextView title = label("Бетельгейзе", 30, Color.WHITE);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        layout.addView(title);
        status = label("", 13, ACCENT);
        status.setPadding(0, px(4), 0, px(8));
        layout.addView(status);

        connect = column();
        name = field("Ваше имя", false);
        name.setText(session.name);
        connect.addView(name);
        invite = field("Вставьте ссылку-приглашение", false);
        invite.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        connect.addView(invite);
        LinearLayout buttons = row();
        equalButton(buttons, "Приглашение по Wi-Fi", () -> { updateName(); session.host(); });
        equalButton(buttons, "Подключиться", () -> { updateName(); session.join(invite.getText().toString()); });
        connect.addView(buttons);
        EditText relay = field("Ретранслятор (адрес:порт)", false);
        relay.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        relay.setText(session.relayAddress);
        connect.addView(relay);
        connect.addView(button("Создать интернет-приглашение", () -> {
            updateName();
            session.hostInternet(relay.getText().toString());
        }));
        layout.addView(connect);

        actions = column();
        layout.addView(actions);

        peer = label("", 16, Color.WHITE);
        peer.setPadding(0, px(8), 0, px(6));
        peer.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        layout.addView(peer);

        transcript = new ScrollView(this);
        transcript.setFillViewport(true);
        messages = column();
        transcript.addView(messages);
        layout.addView(transcript, new LinearLayout.LayoutParams(-1, 0, 1));

        LinearLayout composer = row();
        draft = field("Сообщение", true);
        composer.addView(draft, new LinearLayout.LayoutParams(0, -2, 1));
        send = button("Отправить", () -> {
            String text = draft.getText().toString();
            if (text.trim().isEmpty()) return;
            if (text.trim().getBytes(StandardCharsets.UTF_8).length > 8192) {
                Toast.makeText(this, "Сообщение слишком длинное", Toast.LENGTH_SHORT).show();
                return;
            }
            session.send(text);
            draft.setText("");
        });
        composer.addView(send);
        layout.addView(composer);
        ScrollView contactsScroll = new ScrollView(this);
        contacts = column();
        contactsScroll.addView(contacts);
        layout.addView(contactsScroll, new LinearLayout.LayoutParams(-1, px(150)));
        contactsScroll.setVisibility(View.GONE);
        render();
    }

    private void render() {
        if (isDestroyed() || status == null) return;
        status.setText(session.status);
        connect.setVisibility(session.busy ? View.GONE : View.VISIBLE);
        actions.removeAllViews();
        if (session.invite != null) {
            LinearLayout links = row();
            equalButton(links, "Копировать", () -> {
                getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Betelgeuse", session.invite));
            });
            equalButton(links, "Поделиться", () -> {
                Intent share = new Intent(Intent.ACTION_SEND).setType("text/plain");
                share.putExtra(Intent.EXTRA_TEXT, session.invite);
                startActivity(Intent.createChooser(share, "Приглашение Betelgeuse"));
            });
            actions.addView(links);
        }
        if (session.busy) actions.addView(button("Отключиться", session::disconnect));
        boolean connected = session.peerID != null;
        if (connected) {
            LinearLayout controls = row();
            if (!session.contacts.containsKey(session.peerID)) equalButton(controls, "В контакты", session::saveContact);
            if (session.call == DirectSession.Call.NONE) {
                equalButton(controls, "Позвонить", () -> microphone(false));
                equalButton(controls, "Файл", this::pickFile);
            } else if (session.call == DirectSession.Call.INCOMING) {
                equalButton(controls, "Ответить", () -> microphone(true));
                equalButton(controls, "Отклонить", session::hangup);
            } else {
                equalButton(controls, session.call == DirectSession.Call.ACTIVE ? "Завершить звонок" : "Отменить вызов", session::hangup);
            }
            actions.addView(controls);
        }
        if (session.incoming != null) {
            TextView offer = label(session.incoming.name + " · " + android.text.format.Formatter.formatFileSize(this, session.incoming.size), 14, Color.WHITE);
            actions.addView(offer);
            LinearLayout accept = row();
            equalButton(accept, "Принять", () -> session.respondFile(true));
            equalButton(accept, "Отклонить", () -> session.respondFile(false));
            actions.addView(accept);
        }
        if (session.transfer != null) actions.addView(label(session.transfer, 13, ACCENT));
        if (session.received != null) actions.addView(button("Сохранить " + session.received.getName(), this::saveFile));

        String label = connected ? session.peerName : session.contacts.get(session.selection);
        peer.setText(label == null ? "" : label);
        peer.setVisibility(label == null ? View.GONE : View.VISIBLE);
        draft.setVisibility(connected ? View.VISIBLE : View.GONE);
        send.setVisibility(connected ? View.VISIBLE : View.GONE);
        messages.removeAllViews();
        for (DirectSession.Message message : session.selectedMessages()) {
            TextView bubble = label(message.text, 16, Color.WHITE);
            bubble.setTextIsSelectable(true);
            bubble.setMaxWidth(Math.max(px(180), getResources().getDisplayMetrics().widthPixels * 3 / 4));
            bubble.setPadding(px(12), px(8), px(12), px(8));
            GradientDrawable shape = new GradientDrawable();
            shape.setColor(message.mine ? OUTGOING : PANEL);
            shape.setCornerRadius(px(14));
            bubble.setBackground(shape);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-2, -2);
            params.gravity = message.mine ? Gravity.END : Gravity.START;
            params.topMargin = px(5);
            messages.addView(bubble, params);
        }
        transcript.post(() -> transcript.scrollTo(0, messages.getHeight()));

        contacts.removeAllViews();
        ((View) contacts.getParent()).setVisibility(connected || session.contacts.isEmpty() ? View.GONE : View.VISIBLE);
        if (!connected && !session.contacts.isEmpty()) {
            contacts.addView(label("Контакты", 15, ACCENT));
            for (Map.Entry<String, String> item : session.contacts.entrySet()) {
                Button contact = button(item.getValue(), () -> { session.selection = item.getKey(); render(); });
                contact.setOnLongClickListener(view -> {
                    new AlertDialog.Builder(this).setTitle("Удалить контакт и переписку?")
                        .setNegativeButton("Отмена", null)
                        .setPositiveButton("Удалить", (dialog, which) -> session.removeContact(item.getKey())).show();
                    return true;
                });
                contacts.addView(contact);
            }
        }
    }

    private void updateName() { session.setName(name.getText().toString()); }

    private void microphone(boolean answer) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            if (answer) session.answer(); else session.startOutgoingCall();
        } else {
            answeringAfterPermission = answer;
            requestPermissions(new String[] {Manifest.permission.RECORD_AUDIO}, MICROPHONE);
        }
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] result) {
        super.onRequestPermissionsResult(request, permissions, result);
        if (request == MICROPHONE && result.length > 0 && result[0] == PackageManager.PERMISSION_GRANTED) {
            microphone(answeringAfterPermission);
        }
    }

    private void pickFile() {
        startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*")
            .addCategory(Intent.CATEGORY_OPENABLE), PICK);
    }

    private void saveFile() {
        fileToSave = session.received;
        if (fileToSave == null) return;
        startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/octet-stream")
            .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, fileToSave.getName()), SAVE);
    }

    @Override protected void onActivityResult(int request, int code, Intent result) {
        super.onActivityResult(request, code, result);
        if (code != RESULT_OK || result == null || result.getData() == null) return;
        Uri uri = result.getData();
        if (request == PICK) {
            try (Cursor cursor = getContentResolver().query(uri,
                new String[] { OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE }, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    session.offer(uri, cursor.getString(0), cursor.isNull(1) ? -1 : cursor.getLong(1));
                }
            } catch (RuntimeException error) {
                Toast.makeText(this, "Не удалось открыть файл", Toast.LENGTH_SHORT).show();
            }
        } else if (request == SAVE && fileToSave != null) {
            File source = fileToSave;
            new Thread(() -> {
                String message;
                try (FileInputStream in = new FileInputStream(source);
                     OutputStream output = getContentResolver().openOutputStream(uri)) {
                    if (output == null) throw new java.io.IOException();
                    byte[] bytes = new byte[32_768];
                    for (int count; (count = in.read(bytes)) != -1;) output.write(bytes, 0, count);
                    message = "Файл сохранён";
                } catch (Exception error) {
                    message = "Не удалось сохранить файл";
                }
                String feedback = message;
                runOnUiThread(() -> Toast.makeText(this, feedback, Toast.LENGTH_SHORT).show());
            }, "betelgeuse-export").start();
        }
    }

    @Override protected void onDestroy() { session.disconnect(); super.onDestroy(); }

    private LinearLayout column() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    private LinearLayout row() {
        LinearLayout view = new LinearLayout(this);
        view.setGravity(Gravity.CENTER_VERTICAL);
        view.setOrientation(LinearLayout.HORIZONTAL);
        return view;
    }

    private void equalButton(LinearLayout row, String title, Runnable action) {
        row.addView(button(title, action), new LinearLayout.LayoutParams(0, -2, 1));
    }

    private static final int TEXT = Color.WHITE;

    private Button button(String title, Runnable action) {
        Button view = new Button(this);
        view.setText(title);
        view.setTextColor(ACCENT);
        view.setAllCaps(false);
        view.setOnClickListener(v -> action.run());
        return view;
    }

    private TextView label(String title, int size, int color) {
        TextView text = new TextView(this);
        text.setText(title);
        text.setTextSize(size);
        text.setTextColor(color);
        return text;
    }

    private EditText field(String hint, boolean multi) {
        EditText field = new EditText(this);
        field.setTextColor(TEXT);
        field.setHintTextColor(0xffadacc1);
        field.setHint(hint);
        field.setSingleLine(!multi);
        field.setMaxLines(multi ? 4 : 1);
        field.setTextSize(15);
        return field;
    }

    private int px(int units) { return Math.round(units * getResources().getDisplayMetrics().density); }
}
