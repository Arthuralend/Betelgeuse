package am.supernova.local;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import android.util.Base64;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class RustCore implements AutoCloseable {
    static { System.loadLibrary("betelgeuse_mobile"); }
    private static native String nativeGenerate();
    private static native long nativeOpen(String directory, String secret, String options);
    private static native int nativeSend(long handle, String command);
    private static native String nativePoll(long handle);
    private static native String nativeError();
    private static native void nativeClose(long handle);

    private long handle;

    RustCore(Context context) throws Exception {
        File directory = new File(context.getFilesDir(), "betelgeuse-rust");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new java.io.IOException("Cannot create data directory");
        Os.chmod(directory.getAbsolutePath(), 0700);
        String secret = identity(context);
        handle = nativeOpen(directory.getAbsolutePath(), secret,
            "{\"listen\":[\"/ip4/0.0.0.0/tcp/0\",\"/ip4/0.0.0.0/udp/0/quic-v1\"],\"server\":false}");
        if (handle == 0) throw new IllegalStateException(nativeError());
    }

    private static String identity(Context context) throws Exception {
        final String alias = "betelgeuse-rust-storage";
        SharedPreferences preferences = context.getSharedPreferences("rust-identity", Context.MODE_PRIVATE);
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        String saved = preferences.getString("identity", null);
        if (!store.containsAlias(alias)) {
            if (saved != null) throw new IllegalStateException("Ключ Android Keystore недоступен");
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build());
            generator.generateKey();
        }
        SecretKey key = (SecretKey) store.getKey(alias, null);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        if (saved != null) {
            byte[] nonce = Base64.decode(preferences.getString("nonce", ""), Base64.NO_WRAP);
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, nonce));
            return new String(cipher.doFinal(Base64.decode(saved, Base64.NO_WRAP)), StandardCharsets.UTF_8);
        }
        String secret = nativeGenerate();
        if (secret == null) throw new IllegalStateException(nativeError());
        cipher.init(Cipher.ENCRYPT_MODE, key);
        byte[] encrypted = cipher.doFinal(secret.getBytes(StandardCharsets.UTF_8));
        if (!preferences.edit().putString("identity", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .putString("nonce", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP)).commit()) {
            throw new java.io.IOException("Не удалось сохранить идентичность");
        }
        return secret;
    }

    void send(String command) {
        if (handle == 0) throw new IllegalStateException("Сеть остановлена");
        if (nativeSend(handle, command) != 0) throw new IllegalStateException(nativeError());
    }

    String poll() { return handle == 0 ? null : nativePoll(handle); }

    @Override public void close() {
        long current = handle;
        handle = 0;
        if (current != 0) nativeClose(current);
    }
}
