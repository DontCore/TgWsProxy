# TgWsProxy (iOS)

Порт ядра [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (Flowseal, MIT) на iOS/Swift: **локальный MTProto-прокси** для Telegram прямо на телефоне. Telegram подключается к `127.0.0.1:1443` как к обычному MTProto-прокси, а приложение перекладывает трафик в TLS-WebSocket эндпоинты веб-клиента Telegram (`kws{dc}.web.telegram.org/apiws`) — для провайдера это выглядит как обычный веб-телеграм. Внешний сервер не нужен, всё работает на устройстве.

## Что внутри (порт ядра)

| Модуль tg-ws-proxy | Swift-порт |
|---|---|
| `_try_handshake` (разбор обфусцированного init, AES-CTR + SHA256(prekey+secret)) | `MTProto.tryHandshake` |
| `_generate_relay_init` (свой init для апстрима) | `MTProto.generateRelayInit` |
| `_build_crypto_ctx` / `CryptoCtx` (4 контекста ре-шифрования) | `MTProto.buildCryptoBridge` / `CryptoBridge` |
| `MsgSplitter` (нарезка потока в MTProto-пакеты для WS-фреймов) | `MsgSplitter` |
| `RawWebSocket` → заменён на родной `NWProtocolWebSocket` | `WsUpstream` |
| `_tcp_fallback` (прямой TCP к DC) | `TcpUpstream` |
| `_handle_client` / `bridge_ws_reencrypt` | `ClientBridge` |

Крипта: CommonCrypto (AES-CTR) + CryptoKit (SHA256). MVP поддерживает транспорты abridged / intermediate / padded-intermediate (`dd`-секрет) и тестовые DC (10001+). Не портированы: FakeTLS, Cloudflare h2/worker фолбэки, пулы соединений — WS-путь для DC2/DC4 + TCP-фолбэк для остальных DC.

## Сборка без Mac

1. Залей папку в публичный репозиторий GitHub → вкладка **Actions** → сборка «Build TgWsProxy IPA» → скачай артефакт `TgWsProxy-unsigned-ipa`.
2. Установка на iPhone — как у GiveSharing: [Sideloadly](https://sideloadly.io) + обычный Apple ID (7 дней подписи), Режим разработчика включён.

## Использование

1. Запусти TgWsProxy и нажми **«Запустить прокси»** (приложение должно оставаться открытым — экран не гаснет, пока прокси работает).
2. Нажми **«Открыть в Telegram»** — Telegram предложит добавить прокси `127.0.0.1:1443` (секрет генерируется на телефоне). Либо скопируй ссылку и открой вручную.
3. Готово — Telegram ходит через WebSocket веб-клиента.

## Ограничения MVP

- **Работает только при открытом приложении.** iOS замораживает фоновые приложения — для 24/7 нужен Network Extension (Packet Tunnel Provider + VPN-профиль). Это следующий этап: то же протокольное ядро переносится в extension-процесс без изменений.
- WS-мост работает для DC2/DC4 (как дефолт `--dc-ip` в оригинале); остальные DC — через прямой TCP-фолбэк.
- FakeTLS-маскирование и CF-фолбэки не портированы (на localhost они и не нужны — DPI не видит локальную ногу).
