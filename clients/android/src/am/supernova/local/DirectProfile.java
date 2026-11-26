package am.supernova.local;

import android.util.Base64;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.X509EncodedKeySpec;
import org.json.JSONObject;

final class DirectProfile {
    private final PrivateKey privateKey;
    private final PublicKey publicKey;

    DirectProfile() throws Exception {
        KeyStore store = DirectTLS.localKeyStore();
        privateKey = (PrivateKey) store.getKey(DirectTLS.ALIAS, null);
        publicKey = store.getCertificate(DirectTLS.ALIAS).getPublicKey();
    }

    JSONObject payload(String role, String token, String name) throws Exception {
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(privateKey);
        signer.update(transcript(role, token, name));
        return new JSONObject().put("v", DirectWire.VERSION).put("name", name)
            .put("key", Base64.encodeToString(publicKey.getEncoded(), Base64.NO_WRAP))
            .put("signature", Base64.encodeToString(signer.sign(), Base64.NO_WRAP));
    }

    static String verify(JSONObject remote, String role, String token) throws Exception {
        String name = remote.getString("name"), key = remote.getString("key"), signature = remote.getString("signature");
        if (name.isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 256 || key.length() > 160 || signature.length() > 112) {
            throw new IOException("Некорректный профиль");
        }
        PublicKey parsed = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(Base64.decode(key, Base64.NO_WRAP)));
        if (!(parsed instanceof ECPublicKey) || ((ECPublicKey) parsed).getParams().getCurve().getField().getFieldSize() != 256) {
            throw new IOException("Некорректный ключ профиля");
        }
        Signature verifier = Signature.getInstance("SHA256withECDSA");
        verifier.initVerify(parsed);
        verifier.update(transcript(role, token, name));
        if (!verifier.verify(Base64.decode(signature, Base64.NO_WRAP))) {
            throw new IOException("Подпись профиля не прошла проверку");
        }
        return DirectWire.fingerprint(parsed.getEncoded());
    }

    private static byte[] transcript(String role, String token, String name) {
        return ("betelgeuse-direct-v1\n" + role + "\n" + token + "\n" + name).getBytes(StandardCharsets.UTF_8);
    }
}
