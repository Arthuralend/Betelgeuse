#!/usr/bin/env bash
# Install a dedicated authenticated TURN relay on a fresh Ubuntu host.
set -euo pipefail
if [[ "$(id -u)" != 0 ]]; then echo "Запустите от root."; exit 1; fi
ip=${1:-}
if ! python3 - "$ip" <<'PY'
import ipaddress,sys
try:
    value=ipaddress.IPv4Address(sys.argv[1])
    assert value.is_global
except (ValueError,AssertionError):
    sys.exit(1)
PY
then echo "Укажите публичный IPv4 сервера."; exit 1; fi
if ! ip -4 address show | grep -Fq "inet $ip/"; then
    echo "Публичный адрес не назначен интерфейсу. Для сервера за NAT нужна отдельная конфигурация."; exit 1
fi
if dpkg-query -W -f='${Status}' coturn 2>/dev/null | grep -q 'install ok installed'; then
    echo "coturn уже установлен. Существующая конфигурация не изменена."; exit 1
fi
if ss -H -lntup | grep -Eq ':(47383|474[0-5][0-9]|4746[0-3])\b'; then
    echo "Один из нужных портов занят. Ничего не изменено."; exit 1
fi
apt-get update
apt-get install -y coturn openssl
systemctl stop coturn
password=$(openssl rand -hex 24)
umask 077
cat >/etc/turnserver.conf <<CONF
listening-port=47383
listening-ip=$ip
relay-ip=$ip
realm=betelgeuse.local
fingerprint
lt-cred-mech
user=betelgeuse:$password
min-port=47400
max-port=47463
user-quota=8
total-quota=32
no-cli
no-tls
no-dtls
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
CONF
chown root:turnserver /etc/turnserver.conf
chmod 640 /etc/turnserver.conf
systemctl enable --now coturn
systemctl is-active --quiet coturn || { echo "TURN не запущен."; exit 1; }
echo "TURN запущен. Для доступа снаружи разрешите TCP/UDP 47383 и UDP 47400-47463 в действующем firewall."
echo "Сохраните эти параметры локально; пароль не публикуйте и не отправляйте в чат."
printf 'STUN/TURN URL: stun:%s:47383,turn:%s:47383?transport=udp,turn:%s:47383?transport=tcp\nTURN логин: betelgeuse\nTURN пароль: %s\n' "$ip" "$ip" "$ip" "$password"
