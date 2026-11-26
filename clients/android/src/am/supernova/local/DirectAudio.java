package am.supernova.local;

import android.annotation.SuppressLint;
import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import java.util.Arrays;
import java.util.function.Consumer;

final class DirectAudio implements AutoCloseable {
    private static final int RATE = 16_000;
    private final AudioRecord record;
    private final AudioTrack player;
    private final AudioManager manager;
    private final int oldMode;
    private volatile boolean active;
    private Thread capture;

    @SuppressLint("MissingPermission")
    DirectAudio(Context context, Consumer<byte[]> send, Runnable onFailure) {
        manager = context.getSystemService(AudioManager.class);
        oldMode = manager.getMode();
        record = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, Math.max(3200,
            AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)));
        try {
            player = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(new AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(Math.max(3840,
                    AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)))
                .build();
        } catch (RuntimeException error) {
            record.release();
            throw error;
        }
        try {
            if (record.getState() != AudioRecord.STATE_INITIALIZED || player.getState() != AudioTrack.STATE_INITIALIZED) {
                throw new IllegalStateException("Устройство аудио недоступно");
            }
            manager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            record.startRecording();
            player.play();
            active = true;
            capture = new Thread(() -> {
                byte[] buffer = new byte[640];
                while (active) {
                    int count = record.read(buffer, 0, buffer.length);
                    if (count < 0) {
                        if (active) onFailure.run();
                        break;
                    }
                    if (count > 0 && active) send.accept(Arrays.copyOf(buffer, count));
                }
            }, "supernova-audio");
            capture.start();
        } catch (RuntimeException error) {
            close();
            throw error;
        }
    }

    void receive(byte[] pcm) {
        if (active && pcm.length > 0 && pcm.length <= 4096 && pcm.length % 2 == 0) {
            player.write(pcm, 0, pcm.length, AudioTrack.WRITE_NON_BLOCKING);
        }
    }

    @Override public void close() {
        active = false;
        try { record.stop(); } catch (IllegalStateException ignored) {}
        try { if (capture != null) capture.join(100); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
        record.release();
        player.release();
        manager.setMode(oldMode);
    }
}
