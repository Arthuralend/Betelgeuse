package am.supernova.local;

import android.os.Handler;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.SSLSocket;
import org.json.JSONObject;

final class DirectLink {
    interface Receiver {
        void packet(DirectLink link, DirectWire.Packet packet) throws Exception;
        void closed(DirectLink link, String reason);
    }

    final SSLSocket socket;
    private final DataOutputStream output;
    private final DataInputStream input;
    private final Receiver receiver;
    private final Handler main;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicInteger waitingAudio = new AtomicInteger();
    private final ThreadPoolExecutor writer = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
        new LinkedBlockingQueue<>(32));

    DirectLink(SSLSocket socket, Receiver receiver, Handler main) throws IOException {
        this.socket = socket;
        this.receiver = receiver;
        this.main = main;
        output = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));
        input = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
    }

    DirectWire.Packet readHandshake() throws IOException { return DirectWire.read(input); }

    void readLoop() {
        try {
            while (!closed.get()) {
                DirectWire.Packet packet = DirectWire.read(input);
                CountDownLatch handled = new CountDownLatch(1);
                main.post(() -> {
                    try {
                        if (!closed.get()) receiver.packet(this, packet);
                    } catch (Exception error) {
                        close(error.getMessage());
                    } finally {
                        handled.countDown();
                    }
                });
                handled.await();
            }
        } catch (EOFException error) {
            close("Собеседник отключился");
        } catch (Exception error) {
            close(error.getMessage());
        }
    }

    void fire(int type) { fire(type, new byte[0], null); }

    void fireJson(int type, JSONObject json) {
        fire(type, json.toString().getBytes(StandardCharsets.UTF_8), null);
    }

    void fire(int type, byte[] data, Runnable sent) {
        if (closed.get()) return;
        try {
            writer.execute(() -> {
                try {
                    send(type, data);
                    if (sent != null) main.post(sent);
                } catch (IOException error) {
                    close(error.getMessage());
                }
            });
        } catch (RejectedExecutionException error) {
            if (!closed.get()) close("Очередь отправки переполнена");
        }
    }

    void audio(byte[] data) {
        if (waitingAudio.incrementAndGet() > 3) {
            waitingAudio.decrementAndGet();
            return;
        }
        fire(DirectWire.AUDIO, data, waitingAudio::decrementAndGet);
    }

    synchronized void send(int type, byte[] data) throws IOException {
        if (closed.get()) throw new EOFException("Соединение закрыто");
        DirectWire.write(output, type, data);
    }

    void close(String reason) {
        if (!closed.compareAndSet(false, true)) return;
        try { socket.close(); } catch (IOException ignored) {}
        writer.shutdownNow();
        main.post(() -> receiver.closed(this, reason == null ? "Соединение закрыто" : reason));
    }
}
