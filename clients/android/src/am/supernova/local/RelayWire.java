package am.supernova.local;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;

final class RelayWire {
    static final String SCHEME = "betelgeuse-relay";
    private static final int CONNECT_TIMEOUT = 12_000;

    static String newSlot() {
        byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        return DirectWire.hex(random);
    }

    static void connect(Socket socket, Address address, String slot, boolean host) throws IOException {
        socket.connect(new InetSocketAddress(address.host, address.port), CONNECT_TIMEOUT);
        socket.setTcpNoDelay(true);
        socket.setSoTimeout(CONNECT_TIMEOUT);
        String preface = "BGL1 " + (host ? "H" : "G") + " " + slot + "\n";
        socket.getOutputStream().write(preface.getBytes(StandardCharsets.US_ASCII));
        expect(socket, host ? 'W' : 'K');
    }

    static void awaitGuest(Socket socket) throws IOException {
        socket.setSoTimeout(615_000);
        expect(socket, 'K');
    }

    private static void expect(Socket socket, int signal) throws IOException {
        int answer = socket.getInputStream().read();
        if (answer != signal) throw new IOException(answer == 'E'
            ? "Приглашение недоступно или срок его действия истёк" : "Ретранслятор закрыл соединение");
    }

    static final class Address {
        final String host;
        final int port;

        private Address(String host, int port) { this.host = host; this.port = port; }

        static Address parse(String input) {
            String value = input.trim();
            if (value.length() > 262) return null;
            try {
                URI uri = new URI(SCHEME + "://" + value);
                return uri.getRawPath().isEmpty() ? from(uri) : null;
            } catch (java.net.URISyntaxException error) { return null; }
        }

        static Address from(URI uri) {
            String host = uri.getHost();
            int port = uri.getPort();
            if (!SCHEME.equals(uri.getScheme()) || host == null || port < 1 || port > 65535 ||
                uri.getUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null ||
                host.length() > 255 || host.contains("%")) return null;
            if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
            return new Address(host, port);
        }

        String authority() { return (host.contains(":") ? "[" + host + "]" : host) + ":" + port; }
    }
}
