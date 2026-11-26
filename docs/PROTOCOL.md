# Betelgeuse v1

- libp2p TCP/Noise/Yamux и QUIC.
- Отдельные протоколы /betelgeuse/kad/1.0.0, /betelgeuse/message/1.0.0.
- Ed25519, PeerId от публичного ключа libp2p.
- DHT принимает только ключи /betelgeuse/account/1/<PeerId> и
  /betelgeuse/routes/1/<PeerId>. JSON-объект SignedRecord ограничен 8192 байт.
- Подпись Ed25519 над ASCII доменом betelgeuse:record:1, нулевым байтом,
  далее UTF-8 JSON Body в порядке полей Rust struct без пробелов.
  Публичный ключ — protobuf libp2p key, закодированный base64url без padding.
  Целочисленные поля записываются десятичными числами.
- Account: payload type=account, name — строка UTF-8 до 120 байт или null.
  TTL до 24 часов. Routes: type=routes, peer_record — стандартный
  подписанный libp2p PeerRecord, protobuf signed envelope base64url.
  TTL до 30 минут, до 8 доступных direct или Circuit Relay v2 multiaddr.
- Монотонные номера версии сохраняются в SQLite. Ровно идентичная повторная
  запись допустима. Конфликты одного номера и откат отвергаются. Окно
  допуска расхождения часов — 60 секунд. Номера версий сохраняются 7 дней
  после окончания срока действия.
- Приглашение betelgeuse://v1/<base64url JSON {account,routes}>.
  Оба объекта независимо верифицируются и относятся к одному PeerId.
- Приватные данные хранятся на конечных устройствах. Chat request-response
  CBOR {id: UUID, text: UTF-8}, ответ {id, accepted}. ACK означает
  запись сообщения в локальную БД адресата. Дедупликация по PeerId и UUID.
- Kademlia put quorum — ответ сетевого протокола, подтверждение
  валидации полученных записей отдельно фиксируется событием record_stored.
- Публичные маршруты раскрывают сетевые адреса; подпись подтверждает
  владельца записи, но не гарантирует доступность адреса или честность узла.
  Нет защиты от всех Sybil/Eclipse атак. База ограничена 5000 записями,
  кадры сообщений и одновременно выполняемые локальные запросы ограничены.
- Устройства за NAT могут работать как DHT-клиенты. В этой стадии используются AutoNAT, relay v2 и DCUtR.
  Полноценное автоматическое обнаружение узлов ретрансляции и фоновые
  мобильные звонки требуют следующих этапов. Для DHT требуется как минимум доступный bootstrap.

## Обмен 0.7.0

- /betelgeuse/exchange/1.0.0: отдельные CBOR request-response запросы
  только для сохранённых контактов, authenticated PeerId и UUID сессии.
- WebRTC: invite/accept/reject/busy/offer/answer/ice/hangup. Камера и
  микрофон включаются после двустороннего согласия. SDP и ICE передаются
  через libp2p; медиа шифруется стандартным WebRTC DTLS-SRTP и использует ICE.
  STUN/TURN задаёт пользователь, учётные данные не публикуются.
- FileOffer сообщает имя, размер и SHA-256; получатель сам запрашивает
  последовательные блоки (32 КиБ, максимум 256 МиБ), контролирует размер
  и SHA-256 перед фиксацией, отправляет подтверждение FileFinish.
  Pause/resume в текущем процессе, отмена, лимиты одновременных передач.
  Полные файлы сохраняются в приватном каталоге устройства.
- Устройство не принимает произвольный путь от удалённого партнёра.
  Сигнализация и файлы используют Noise/QUIC или защищённое соединение
  через Circuit Relay v2. Relay не маршрутизирует WebRTC-медиа.

## Pairing and trusted bootstrap (0.8.0)

- /betelgeuse/pair/1.0.0: CBOR request {id,link}, response {id,link|null}.
  A pair offer is a signed Invitation bound to the authenticated PeerId.
  Save no contact until explicit acceptance by the receiver. The sender
  imports only a verified reply for its request and peer. Offers expire
  and pending work is bounded.
- The local DNS-SD advertisement uses _betelgeuse._tcp and the actual
  listener port. Peer ID and display name are untrusted hints until
  verified by the authenticated pairing exchange.
- Apple-only nearby pairing can use encrypted MultipeerConnectivity to
  exchange invitations after consent; receiver verifies the signed profile
  against the advertised Rust Peer ID before offering acceptance.
- Configured bootstrap nodes are locally persisted and identity-pinned;
  a detected arbitrary network peer is not automatically trusted as relay.
  Relay routes are periodically republished; local-only addresses are not
  part of the automatic DHT route publication.
