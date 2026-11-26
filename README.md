# Betelgeuse / Бетельгейзе

Rust/libp2p, версия 0.8.0: общее сетевое ядро CLI, iOS и Android, новый режим звонков и файлов.
Мобильные сборки 0.3.0 используют прежний протокол; переход на Rust требует
отдельной проверенной интеграции и миграции идентичности.

### Сборка и проверка

```sh
rustup update stable
cargo generate-lockfile
cargo test --workspace --locked
cargo build -p betelgeuse --locked
python3 tests/two_nodes.py
```

Для проверки сканирования QR установите `rsvg-convert` и `zbarimg` и добавьте
`--require-qr`. В GitHub Actions Linux запускает этот тест обязательно.
Затем macOS runner делает сборку с тем же Cargo.lock.

### Два узла

Первый терминал:

```sh
cargo run -p betelgeuse -- --data-dir ./alice account create
cargo run -p betelgeuse -- --data-dir ./alice node start --server
```

Скопируйте полный адрес из события `listen`. Второй терминал:

```sh
cargo run -p betelgeuse -- --data-dir ./bob account create
cargo run -p betelgeuse -- --data-dir ./bob node start --server --bootstrap '<адрес Alice с /p2p/PeerID>'
```

Для интернета оператор узла может указать слушающий интерфейс и реальный
публично доступный адрес; Circuit Relay v2 доступен при запуске добровольного узла
с флагом `--relay-server`. Реализованы AutoNAT и DCUtR; успешность
прямого обновления зависит от NAT и маршрутизаторов. Локальный CLI по умолчанию привязан к loopback.
`--server` разрешает обслуживание DHT, без флага узел работает клиентом.
Начальный адрес берётся из приглашения или списка bootstrap, фиксированного
узла разработчика нет.

Активный процесс принимает JSON-строки через stdin; stdout возвращает события:

```jsonl
{"op":"status"}
{"op":"connect","address":"/ip4/127.0.0.1/tcp/4001/p2p/<PeerID>"}
{"op":"bootstrap"}
{"op":"announce","address":"<доступный адрес этого узла>"}
{"op":"reserve_relay","address":"<адрес ретранслятора с /p2p/PeerID>"}
{"op":"invite","name":"Alice","qr_path":"alice.svg"}
{"op":"import","link":"betelgeuse://v1/..."}
{"op":"contacts"}
{"op":"put","name":"Alice"}
{"op":"publish_routes"}
{"op":"get","peer":"<PeerID>","kind":"account"}
{"op":"get","peer":"<PeerID>","kind":"routes"}
{"op":"send","peer":"<PeerID>","text":"Hello"}
{"op":"retry","peer":"<PeerID>"}
{"op":"quit"}
```

Для приглашения и публикации маршрутов можно явно передать `addresses` —
массив direct или circuit relay multiaddr без конечного `/p2p`. По умолчанию берутся адреса listeners.
Приглашение не является секретом авторизации: оно подтверждает профиль и
маршрут. Два собеседника должны осознанно обменяться приглашениями.
Сообщения от неизвестных контактов отклоняются; исходящие хранятся до ACK,
повтор отправляется по команде retry или при новом соединении.

### Где хранится информация

В приватной директории аккаунта: `identity.pb` (Ed25519), `state.sqlite3`
(контакты, сообщения, максимальные версии записей). История CLI
защищена файловыми разрешениями, дополнительное шифрование базы ожидает
выбора стандартного решения. Сохранение и восстановление CLI-идентичности:
остановить узел, безопасно скопировать всю приватную директорию в
зашифрованное резервное хранилище, при восстановлении вернуть права 700/600.

### Статус проверки

Результаты компиляции и сетевого теста определяет GitHub Actions. На Mac
первоначальная сборка была недоступна из-за отсутствия Rust/Cargo,
ограниченного доступа к реестру crates и недостатка свободного места.
Состояние первого этапа нельзя считать подтверждённым до успешного CI.

В ветке 0.6.0 добавлены C FFI, JNI, нативные экраны и сборки IPA/APK.
Новый режим поддерживает поиск, приглашения, текстовый чат, передачу файлов и WebRTC-сигнализацию.
Старый протокол и локальная история 0.3.0 доступны отдельно в режиме
совместимости. Криптографическая миграция между P-256 и Ed25519 требует
двустороннего подтверждения и ещё не реализована. iOS сохраняет новое
удостоверение в Keychain, Android шифрует его ключом Android Keystore.
В 0.7.0 добавлены двусторонние голосовые и видеозвонки на нативном WebRTC
с сигнализацией через аутентифицированный libp2p. Передача файлов
до 256 МиБ через защищённый libp2p использует подтверждение получателя и
SHA-256. Пауза и возобновление доступны в рамках текущего запуска.
Медиа использует прямой маршрут ICE, а при невозможности - пользовательский TURN.
Circuit Relay v2 передаёт файлы и сигнализацию, но не заменяет TURN.
Физические телефоны необходимо проверить отдельно.
GitHub Actions производит unsigned IPA и APK; не храните ключи подписи
в репозитории. Пользовательские бинарные артефакты подписываются отдельно.

### Добровольная ретрансляция

Узел с доступным IP: `node start --server --relay-server --listen /ip4/0.0.0.0/tcp/4001`.
После запуска явно укажите доступный адрес через команду announce.
На клиенте: reserve_relay с полным адресом узла. После события relay_reserved
и нового listen, включите полученный маршрут в приглашение/публикацию routes
(без конечного /p2p/<свой PeerId>). Все подключения проверяют PeerId.
Тест локальных процессов: `python3 tests/relay_nodes.py`. Реальный NAT/CGNAT
отдельно проверяется на разных физических сетях.

### Сборка мобильных клиентов

После создания Cargo.lock:

```sh
bash scripts/build-ios.sh
# Требуются ANDROID_HOME, ANDROID_NDK_HOME и JAVA_HOME
bash scripts/build-android.sh
```

В GitHub Actions создаются отдельные артефакты для iOS и Android после
в независимых заданиях для обеих платформ. На Android новый режим открывается
по умолчанию, совместимость 0.3.0 доступна кнопкой внизу экрана.

Тест нового обмена: `python3 tests/exchange_nodes.py`. См. [инструкцию проверки](docs/QUICKSTART-RU.md).

### 0.8.0

Automated trusted bootstrap and relay, persistent settings, bounded contact-route refresh, new-port TCP dialing, consented nearby peer pairing by native DNS-SD (iOS/Android) and MultipeerConnectivity (Apple), audio graph compatibility fix. See [QUICKSTART-RU.md](docs/QUICKSTART-RU.md).
