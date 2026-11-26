package am.supernova.local;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.util.Collections;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.X509TrustManager;

final class DirectTLS {
    static final String ALIAS = "supernova-direct-ec";

    static synchronized KeyStore localKeyStore() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (!store.containsAlias(ALIAS)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                .setCertificateSubject(new javax.security.auth.x500.X500Principal("CN=Supernova Direct"))
                .build());
            generator.generateKeyPair();
        }
        return store;
    }

    static Host host() throws Exception {
        KeyStore store = localKeyStore();
        KeyManagerFactory factory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        factory.init(store, null);
        SSLContext context = SSLContext.getInstance("TLSv1.3");
        context.init(factory.getKeyManagers(), null, null);
        byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        return new Host(context, DirectWire.fingerprint(store.getCertificate(ALIAS).getEncoded()), DirectWire.hex(random));
    }

    static SSLContext client(String pin) throws Exception {
        X509TrustManager trust = new X509TrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                throw new CertificateException("Unexpected client certificate");
            }
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                if (chain == null || chain.length == 0) throw new CertificateException("Missing certificate");
                try {
                    String actual = DirectWire.fingerprint(chain[0].getEncoded());
                    if (!constantEquals(actual, pin)) throw new CertificateException("Отпечаток приглашения не совпал");
                } catch (java.security.NoSuchAlgorithmException error) {
                    throw new CertificateException(error);
                }
            }
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        };
        SSLContext context = SSLContext.getInstance("TLSv1.3");
        context.init(null, new X509TrustManager[] { trust }, null);
        return context;
    }

    static boolean constantEquals(String left, String right) {
        return MessageDigest.isEqual(left.getBytes(StandardCharsets.UTF_8), right.getBytes(StandardCharsets.UTF_8));
    }

    static Inet4Address localAddress() throws Exception {
        Inet4Address fallback = null;
        for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
            if (!network.isUp() || network.isLoopback()) continue;
            for (InetAddress address : Collections.list(network.getInetAddresses())) {
                if (!(address instanceof Inet4Address) || !address.isSiteLocalAddress()) continue;
                if (network.getName().startsWith("wlan") || network.getName().startsWith("ap")) {
                    return (Inet4Address) address;
                }
                if (fallback == null) fallback = (Inet4Address) address;
            }
        }
        if (fallback != null) return fallback;
        throw new java.io.IOException("Подключитесь к Wi-Fi и попробуйте снова");
    }

    static final class Host {
        final SSLContext context;
        final String fingerprint, token;
        Host(SSLContext context, String fingerprint, String token) {
            this.context = context;
            this.fingerprint = fingerprint;
            this.token = token;
        }
    }
}
