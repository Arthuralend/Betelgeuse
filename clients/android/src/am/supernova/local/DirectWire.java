package am.supernova.local;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.security.MessageDigest;

final class DirectWire {
    static final int HELLO = 1, WELCOME = 2, TEXT = 3, OFFER = 4, ACCEPT = 5, DECLINE = 6;
    static final int CHUNK = 7, DONE = 8, RECEIVED = 9, CALL = 10, ANSWER = 11, HANGUP = 12, AUDIO = 13, KEEPALIVE = 14;
    static final int MAX_BODY = 65_536;
    static final int VERSION = 1;

    static Packet read(DataInputStream in) throws IOException {
        int type = in.readUnsignedByte();
        int length = in.readInt();
        if (type < HELLO || type > KEEPALIVE || length < 0 || length > MAX_BODY) {
            throw new IOException("Несовместимый сетевой пакет");
        }
        byte[] data = new byte[length];
        in.readFully(data);
        return new Packet(type, data);
    }

    static void write(DataOutputStream out, int type, byte[] data) throws IOException {
        if (type < HELLO || type > KEEPALIVE || data.length > MAX_BODY) {
            throw new IOException("Некорректный сетевой пакет");
        }
        out.writeByte(type);
        out.writeInt(data.length);
        out.write(data);
        out.flush();
    }

    static String hex(byte[] bytes) {
        char[] alphabet = "0123456789abcdef".toCharArray();
        char[] answer = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 255;
            answer[i * 2] = alphabet[value >>> 4];
            answer[i * 2 + 1] = alphabet[value & 15];
        }
        return new String(answer);
    }

    static String fingerprint(byte[] bytes) throws java.security.NoSuchAlgorithmException {
        return hex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    static final class Packet {
        final int type;
        final byte[] data;

        Packet(int type, byte[] data) {
            this.type = type;
            this.data = data;
        }
    }

    private DirectWire() {}
}
