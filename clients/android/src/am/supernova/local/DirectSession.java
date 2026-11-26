package am.supernova.local;

import static am.supernova.local.DirectWire.*;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import org.json.JSONArray;
import org.json.JSONObject;

final class DirectSession implements DirectLink.Receiver {
    private static final long MAX_FILE = 1_073_741_824L;
    private static final byte[] EMPTY = new byte[0];
    enum Call { NONE, INCOMING, OUTGOING, ACTIVE }

    final Handler main = new Handler(Looper.getMainLooper());
    final Context app;
    final Runnable onChange;
    final SharedPreferences preferences;
    final Map<String, String> contacts = new LinkedHashMap<>();
    final Map<String, List<Message>> history = new HashMap<>();
    String relayAddress;
    String name, invite, peerID, peerName, selection, status = "Готово к подключению", transfer;
    boolean busy;
    Call call = Call.NONE;
    Offer incoming;
    File received;
    volatile DirectLink link;
    private volatile Attempt attempt;
    private DirectAudio audio;
    private Offer outgoing;
    private IncomingFile receiving;
    private boolean waitingForReceipt;

    DirectSession(Context context, Runnable onChange) {
        app = context.getApplicationContext();
        this.onChange = onChange;
        preferences = app.getSharedPreferences("direct", Context.MODE_PRIVATE);
        name = preferences.getString("name", "Android");
        relayAddress = preferences.getString("relay", "");
        try {
            JSONObject saved = new JSONObject(preferences.getString("contacts", "{}"));
            saved.keys().forEachRemaining(id -> contacts.put(id, saved.optString(id)));
            for (String id : contacts.keySet()) {
                JSONArray entries = new JSONArray(preferences.getString("chat:" + id, "[]"));
                List<Message> list = new ArrayList<>();
                for (int i = 0; i < entries.length(); i++) {
                    JSONObject entry = entries.getJSONObject(i);
                    list.add(new Message(entry.getString("text"), entry.getBoolean("mine")));
                }
                history.put(id, list);
            }
        } catch (Exception ignored) {}
    }

    void setName(String name) {
        name = name.trim();
        this.name = name.isEmpty() ? "Android" : name;
        if (this.name.length() > 40) this.name = this.name.substring(0, 40);
        preferences.edit().putString("name", this.name).apply();
    }

    void host() {
        if (busy) return;
        Attempt job = begin("Создаю приглашение…");
        String ownName = name;
        launch(() -> {
            try {
                DirectTLS.Host config = DirectTLS.host();
                Inet4Address address = DirectTLS.localAddress();
                try (SSLServerSocket server = (SSLServerSocket) config.context.getServerSocketFactory().createServerSocket()) {
                    job.setServer(server);
                    server.setEnabledProtocols(new String[] {"TLSv1.3"});
                    server.bind(new InetSocketAddress(address, 0));
                    main.post(() -> {
                        if (attempt != job) return;
                        invite = "betelgeuse://" + address.getHostAddress() + ":" + server.getLocalPort()
                            + "/" + config.fingerprint + "/" + config.token;
                        notice("Передайте приглашение собеседнику");
                    });
                    while (!server.isClosed()) {
                        SSLSocket socket = (SSLSocket) server.accept();
                        try {
                            establish(job, socket, config.token, true, ownName, false);
                            break;
                        } catch (Exception error) {
                            socket.close();
                            main.post(() -> {
                                if (attempt == job && busy) notice("Подключение отклонено. Приглашение ещё действует.");
                            });
                        }
                    }
                }
            } catch (Exception error) {
                failure(job, error);
            }
        });
    }

    void join(String input) {
        if (busy) return;
        String clean = input.trim();
        if (clean.startsWith(RelayWire.SCHEME + "://")) {
            joinInternet(clean);
            return;
        }
        Uri uri = Uri.parse(clean);
        String address = uri.getHost();
        List<String> path = uri.getPathSegments();
        int port = uri.getPort();
        if (!"betelgeuse".equals(uri.getScheme()) || address == null || !address.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}") ||
            port < 1 || port > 65535 || uri.getEncodedUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null ||
            path.size() != 2 || !path.get(0).matches("[0-9a-f]{64}") || !path.get(1).matches("[0-9a-f]{64}")) {
            notice("Вставьте действительную ссылку-приглашение Betelgeuse");
            return;
        }
        Attempt job = begin("Устанавливаю защищённое соединение…");
        String ownName = name;
        launch(() -> {
            try {
                SSLSocket socket = (SSLSocket) DirectTLS.client(path.get(0)).getSocketFactory().createSocket();
                job.setSocket(socket);
                socket.connect(new InetSocketAddress(address, port), 12_000);
                establish(job, socket, path.get(1), false, ownName, false);
            } catch (Exception error) {
                failure(job, error);
            }
        });
    }

    void hostInternet(String input) {
        if (busy) return;
        RelayWire.Address address = RelayWire.Address.parse(input);
        if (address == null) { notice("Укажите адрес и порт ретранслятора"); return; }
        relayAddress = address.authority();
        preferences.edit().putString("relay", relayAddress).apply();
        Attempt job = begin("Подключаюсь к ретранслятору…");
        String ownName = name;
        launch(() -> {
            try {
                DirectTLS.Host config = DirectTLS.host();
                String slot = RelayWire.newSlot();
                Socket transport = new Socket();
                job.setTransport(transport);
                RelayWire.connect(transport, address, slot, true);
                main.post(() -> {
                    if (attempt != job) return;
                    invite = RelayWire.SCHEME + "://" + address.authority() + "/" + slot + "/" + config.fingerprint + "/" + config.token;
                    notice("Передайте интернет-приглашение собеседнику");
                });
                RelayWire.awaitGuest(transport);
                main.post(() -> {
                    if (attempt != job) return;
                    invite = null;
                    notice("Устанавливаю защищённое соединение…");
                });
                SSLSocket secure = (SSLSocket) config.context.getSocketFactory()
                    .createSocket(transport, address.host, address.port, true);
                secure.setUseClientMode(false);
                establish(job, secure, config.token, true, ownName, true);
            } catch (Exception error) {
                failure(job, error);
            }
        });
    }

    private void joinInternet(String input) {
        RelayWire.Address address;
        String[] fields;
        try {
            if (input.length() > 512) throw new IOException();
            URI uri = new URI(input);
            address = RelayWire.Address.from(uri);
            fields = uri.getRawPath().split("/", -1);
            if (address == null || fields.length != 4 || !fields[0].isEmpty() || !fields[1].matches("[0-9a-f]{64}") ||
                !fields[2].matches("[0-9a-f]{64}") || !fields[3].matches("[0-9a-f]{64}")) throw new IOException();
        } catch (Exception error) {
            notice("Ссылка-приглашение повреждена");
            return;
        }
        Attempt job = begin("Подключаюсь к ретранслятору…");
        String ownName = name;
        launch(() -> {
            try {
                Socket transport = new Socket();
                job.setTransport(transport);
                RelayWire.connect(transport, address, fields[1], false);
                SSLSocket secure = (SSLSocket) DirectTLS.client(fields[2]).getSocketFactory()
                    .createSocket(transport, address.host, address.port, true);
                secure.setUseClientMode(true);
                establish(job, secure, fields[3], false, ownName, true);
            } catch (Exception error) {
                failure(job, error);
            }
        });
    }

    private void scheduleKeepalive(DirectLink connection) {
        main.postDelayed(() -> {
            if (link != connection) return;
            connection.fire(KEEPALIVE);
            scheduleKeepalive(connection);
        }, 35_000);
    }

    private Attempt begin(String message) {
        Attempt job = new Attempt();
        attempt = job;
        busy = true;
        notice(message);
        return job;
    }

    private void establish(Attempt job, SSLSocket socket, String token, boolean host, String ownName, boolean relayed) throws Exception {
        job.setSocket(socket);
        socket.setTcpNoDelay(true);
        socket.setSoTimeout(relayed ? 20_000 : 12_000);
        socket.setEnabledProtocols(new String[] {"TLSv1.3"});
        socket.startHandshake();
        DirectLink connection = new DirectLink(socket, this, main);
        DirectProfile profile = new DirectProfile();
        JSONObject local = profile.payload(host ? "host" : "guest", token, ownName);
        if (!host) connection.send(HELLO, json(local.put("token", token)));
        DirectWire.Packet packet = connection.readHandshake();
        JSONObject remote = new JSONObject(utf8(packet.data));
        if (packet.type != (host ? HELLO : WELCOME) || remote.getInt("v") != VERSION ||
            (host && !DirectTLS.constantEquals(remote.getString("token"), token))) {
            throw new IOException("Приглашение отклонено");
        }
        String id = DirectProfile.verify(remote, host ? "guest" : "host", token);
        String label = remote.getString("name");
        if (host) {
            job.stopAccepting();
            connection.send(WELCOME, json(local));
        }
        socket.setSoTimeout(0);
        main.post(() -> {
            if (attempt != job) { connection.close(null); return; }
            link = connection;
            peerID = id;
            peerName = label;
            selection = id;
            invite = null;
            notice(relayed ? "Интернет через ретранслятор · TLS 1.3" : "Прямое соединение · TLS 1.3");
            if (relayed && host) scheduleKeepalive(connection);
        });
        connection.readLoop();
    }

    private void failure(Attempt job, Exception error) {
        job.close();
        main.post(() -> {
            if (attempt != job) return;
            attempt = null;
            busy = false;
            invite = null;
            notice("Ошибка подключения: " + (error.getMessage() == null ? "проверьте сеть и приглашение" : error.getMessage()));
        });
    }

    void disconnect() {
        Attempt job = attempt;
        attempt = null;
        if (job != null) job.close();
        DirectLink connection = link;
        if (connection != null) connection.close("Соединение закрыто");
        reset();
        notice("Готово к подключению");
    }

    @Override public void closed(DirectLink connection, String reason) {
        if (link != connection) return;
        Attempt job = attempt;
        attempt = null;
        if (job != null) job.close();
        reset();
        notice(reason);
    }

    private void reset() {
        link = null;
        history.keySet().retainAll(contacts.keySet());
        if (!contacts.containsKey(selection)) selection = null;
        busy = false;
        invite = null;
        peerID = null;
        peerName = null;
        incoming = null;
        outgoing = null;
        transfer = null;
        waitingForReceipt = false;
        if (receiving != null) receiving.discard();
        receiving = null;
        stopCall();
    }

    void send(String input) {
        byte[] text = jsonBytes(input.trim());
        DirectLink connection = link;
        String id = peerID;
        if (connection == null || id == null || text.length == 0 || text.length > 8192) return;
        connection.fire(TEXT, text, () -> append(id, new Message(input.trim(), true)));
    }

    List<Message> selectedMessages() { return history.getOrDefault(selection, java.util.Collections.emptyList()); }

    void saveContact() {
        if (peerID == null) return;
        if (contacts.size() >= 50 && !contacts.containsKey(peerID)) {
            notice("Можно сохранить до 50 контактов");
            return;
        }
        contacts.put(peerID, peerName);
        preferences.edit().putString("contacts", new JSONObject(contacts).toString()).apply();
        storeHistory(peerID);
        onChange.run();
    }

    void removeContact(String id) {
        contacts.remove(id);
        history.remove(id);
        if (id.equals(selection)) selection = null;
        preferences.edit().putString("contacts", new JSONObject(contacts).toString()).remove("chat:" + id).apply();
        onChange.run();
    }

    private void append(String id, Message entry) {
        List<Message> messages = history.computeIfAbsent(id, unused -> new ArrayList<>());
        messages.add(entry);
        if (messages.size() > 100) messages.remove(0);
        if (contacts.containsKey(id)) storeHistory(id);
        onChange.run();
    }

    private void storeHistory(String id) {
        JSONArray data = new JSONArray();
        for (Message item : history.getOrDefault(id, java.util.Collections.emptyList())) {
            try { data.put(new JSONObject().put("text", item.text).put("mine", item.mine)); }
            catch (org.json.JSONException error) { return; }
        }
        preferences.edit().putString("chat:" + id, data.toString()).apply();
    }

    void offer(Uri uri, String label, long size) {
        if (link == null || outgoing != null || receiving != null || incoming != null || call != Call.NONE) return;
        if (size < 0 || size > MAX_FILE) { notice("Выберите файл известного размера, до 1 ГБ"); return; }
        String name = label == null || label.isEmpty() ? "Файл" : label;
        if (name.length() > 90) name = name.substring(0, 90);
        try {
            outgoing = new Offer(name, size, uri);
            transfer = "Жду согласия на передачу файла";
            link.fireJson(OFFER, new JSONObject().put("name", name).put("size", size));
            onChange.run();
        } catch (org.json.JSONException error) { notice("Не удалось отправить файл"); }
    }

    void respondFile(boolean accept) {
        Offer offer = incoming;
        if (link == null || offer == null) return;
        incoming = null;
        if (!accept) {
            link.fire(DECLINE);
        } else {
            try {
                if (app.getFilesDir().getUsableSpace() < offer.size) throw new IOException("Недостаточно свободного места");
                receiving = new IncomingFile(app.getFilesDir(), offer);
                transfer = "Принимаю " + offer.name + "…";
                link.fire(ACCEPT);
            } catch (Exception error) {
                link.fire(DECLINE);
                status = error.getMessage();
            }
        }
        onChange.run();
    }

    private void sendFile(DirectLink connection, Offer offer) {
        try (InputStream in = app.getContentResolver().openInputStream(offer.uri)) {
            if (in == null) throw new IOException("Не удалось открыть файл");
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[32768];
            long remaining = offer.size;
            while (remaining > 0) {
                int size = in.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                if (size <= 0) throw new IOException("Файл изменился во время передачи");
                digest.update(buffer, 0, size);
                connection.send(CHUNK, Arrays.copyOf(buffer, size));
                remaining -= size;
            }
            connection.send(DONE, digest.digest());
        } catch (Exception error) {
            connection.close(error.getMessage());
        }
    }

    void startOutgoingCall() {
        if (link == null || call != Call.NONE || outgoing != null || incoming != null || receiving != null) return;
        call = Call.OUTGOING;
        link.fire(CALL);
        onChange.run();
    }

    void answer() {
        if (link == null || call != Call.INCOMING) return;
        link.fire(ANSWER);
        startAudio(link);
        onChange.run();
    }

    void hangup() {
        if (link != null && call != Call.NONE) link.fire(HANGUP);
        stopCall();
        onChange.run();
    }

    private void startAudio(DirectLink connection) {
        call = Call.ACTIVE;
        try {
            audio = new DirectAudio(app, connection::audio, () -> main.post(() -> {
                if (link != connection) return;
                notice("Микрофон недоступен");
                hangup();
            }));
        } catch (RuntimeException error) {
            notice("Микрофон недоступен");
            hangup();
        }
    }

    private void stopCall() {
        if (audio != null) audio.close();
        audio = null;
        call = Call.NONE;
    }

    @Override public void packet(DirectLink connection, DirectWire.Packet packet) throws Exception {
        if (connection != link || peerID == null) return;
        switch (packet.type) {
            case KEEPALIVE: return;
            case TEXT:
                if (packet.data.length == 0 || packet.data.length > 8192) throw new IOException("Некорректное сообщение");
                append(peerID, new Message(utf8(packet.data), false));
                return;
            case OFFER:
                JSONObject fields = new JSONObject(utf8(packet.data));
                String name = fields.getString("name");
                long size = fields.getLong("size");
                if (name.isEmpty() || jsonBytes(name).length > 360 || size < 0 || size > MAX_FILE) throw new IOException("Некорректный файл");
                if (incoming != null || receiving != null || outgoing != null || call != Call.NONE) connection.fire(DECLINE);
                else incoming = new Offer(name, size, null);
                break;
            case ACCEPT:
                if (outgoing == null || waitingForReceipt) throw new IOException("Неожиданное подтверждение файла");
                Offer offer = outgoing;
                waitingForReceipt = true;
                transfer = "Передаю " + offer.name + "…";
                launch(() -> sendFile(connection, offer));
                break;
            case DECLINE:
                if (outgoing == null || waitingForReceipt) throw new IOException("Неожиданный отказ");
                outgoing = null;
                transfer = "Собеседник отклонил файл";
                break;
            case CHUNK:
                if (receiving == null) throw new IOException("Файл не принят");
                receiving.add(packet.data);
                return;
            case DONE:
                if (receiving == null) throw new IOException("Файл не принят");
                received = receiving.finish(packet.data);
                receiving = null;
                transfer = "Файл получен и проверен";
                connection.fire(RECEIVED);
                break;
            case RECEIVED:
                if (outgoing == null || !waitingForReceipt) throw new IOException("Неожиданное подтверждение файла");
                outgoing = null;
                waitingForReceipt = false;
                transfer = "Файл доставлен";
                break;
            case CALL:
                if (call == Call.OUTGOING || call == Call.ACTIVE) return;
                if (call != Call.NONE || incoming != null || receiving != null || outgoing != null) connection.fire(HANGUP);
                else call = Call.INCOMING;
                break;
            case ANSWER:
                if (call == Call.OUTGOING) startAudio(connection);
                break;
            case HANGUP:
                stopCall();
                break;
            case AUDIO:
                if (audio != null) audio.receive(packet.data);
                return;
            default:
                throw new IOException("Сетевой пакет не поддерживается");
        }
        onChange.run();
    }

    private void notice(String message) { status = message; onChange.run(); }
    private static byte[] jsonBytes(String text) { return text.getBytes(StandardCharsets.UTF_8); }
    private static byte[] json(JSONObject fields) { return jsonBytes(fields.toString()); }
    private static String utf8(byte[] bytes) throws IOException { return StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString(); }

    private static void launch(Runnable body) { new Thread(body, "supernova-network").start(); }

    static final class Message {
        final String text;
        final boolean mine;
        Message(String text, boolean mine) { this.text = text; this.mine = mine; }
    }

    static final class Offer {
        final String name;
        final long size;
        final Uri uri;

        Offer(String name, long size, Uri uri) {
            this.name = name;
            this.size = size;
            this.uri = uri;
        }
    }

    private static final class IncomingFile {
        private final Offer offer;
        private final File temp;
        private final FileOutputStream output;
        private final MessageDigest digest;
        private long remaining;

        IncomingFile(File directory, Offer offer) throws Exception {
            this.offer = offer;
            remaining = offer.size;
            digest = MessageDigest.getInstance("SHA-256");
            temp = File.createTempFile("transfer", ".part", directory);
            try { output = new FileOutputStream(temp); }
            catch (IOException error) { temp.delete(); throw error; }
        }

        void add(byte[] chunk) throws IOException {
            if (chunk.length == 0 || chunk.length > remaining) throw new IOException("Файл превышает объявленный размер");
            output.write(chunk);
            digest.update(chunk);
            remaining -= chunk.length;
        }

        File finish(byte[] expected) throws IOException {
            if (remaining != 0 || !MessageDigest.isEqual(digest.digest(), expected)) {
                throw new IOException("Контрольная сумма файла не совпала");
            }
            output.close();
            File directory = new File(temp.getParentFile(), "Received/" + UUID.randomUUID());
            if (!directory.mkdirs()) throw new IOException("Не удалось сохранить файл");
            String safe = offer.name.replaceAll("[\\\\/:\\p{Cntrl}]", "_");
            if (safe.isEmpty() || safe.equals(".") || safe.equals("..")) safe = "Файл";
            File file = new File(directory, safe);
            if (!temp.renameTo(file)) throw new IOException("Не удалось сохранить файл");
            return file;
        }

        void discard() {
            try { output.close(); } catch (IOException ignored) {}
            temp.delete();
        }
    }

    private static final class Attempt {
        private SSLServerSocket server;
        private SSLSocket socket;
        private Socket transport;
        private boolean cancelled;

        synchronized void setServer(SSLServerSocket value) throws IOException {
            if (cancelled) { value.close(); throw new IOException("Подключение отменено"); }
            server = value;
        }

        synchronized void setSocket(SSLSocket value) throws IOException {
            if (cancelled) { value.close(); throw new IOException("Подключение отменено"); }
            socket = value;
        }

        synchronized void setTransport(Socket value) throws IOException {
            if (cancelled) { value.close(); throw new IOException("Подключение отменено"); }
            transport = value;
        }

        synchronized void stopAccepting() throws IOException { if (server != null) server.close(); }

        synchronized void close() {
            cancelled = true;
            try { if (server != null) server.close(); } catch (IOException ignored) {}
            try { if (socket != null) socket.close(); } catch (IOException ignored) {}
            try { if (transport != null) transport.close(); } catch (IOException ignored) {}
        }
    }
}
