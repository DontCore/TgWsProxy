# TgWsProxy (iOS)

Порт ядра [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (Flowseal, MIT) на iOS/Swift: **локальный MTProto-прокси** для Telegram прямо на телефоне, работающий в фоне через **VPN-профиль (Packet Tunnel)**, который обслуживает только Telegram. Telegram подключается к `127.0.0.1:1443` как к обычному MTProto-прокси, а прокси перекладывает трафик в TLS-WebSocket эндпоинты веб-клиента Telegram (`kws{dc}.web.telegram.org/apiws`), с Cloudflare-фронтингом при блокировках — ровно как на ПК. Внешний сервер не нужен, всё работает на устройстве.

## Как это работает

```
Telegram iOS ──► 127.0.0.1:1443 (MTProto-прокси)      ← внутри VPN-процесса, живёт 24/7
                        │
                        ▼  WS / Cloudflare-фронтинг
             kws{dc}.web.telegram.org / kws{dc}.{cf-домен}
```

- **VPN-профиль (Packet Tunnel)** — единственный легальный способ держать процесс живым в фоне. В туннель заводится только фиктивная подсеть 10.111.222.0/24: трафик остальных приложений не перехватывается и не тратится батарея, работает исключительно Telegram через его прокси. Значок «VPN» в статус-баре — обязательная плата за фон на iOS.
- **CF-фолбэк** — если провайдер режет прямой WS (как выяснилось на ПК-логе), перебираются Cloudflare-домены `kws{dc}.{cf}` из списка Flowseal'а (авто-обновление), затем TCP-фолбэк в DC.
- Ядро — порт tg_ws_proxy.py/bridge.py: handshake с секретом (AES-CTR), relay-init, 4 контекста ре-шифрования, MsgSplitter, мост в WS.

## Сборка без Mac

1. Залей папку в публичный репозиторий GitHub → **Actions** → «Build TgWsProxy IPA» → артефакт `TgWsProxy-unsigned-ipa` (энтайтменты VPN/App Group вшиваются в бинари через ldid при упаковке).
2. Установка через [Sideloadly](https://sideloadly.io) + Apple ID.

> **Важно про подпись:** VPN-расширению нужен энтайтмент Network Extension. Бесплатный Apple ID подписывает на 7 дней, и Sideloadly обычно переносит энтайтменты, но если iOS откажется поднимать VPN-профиль («не удалось добавить VPN») — это ограничение бесплатной подписи; поможет платный аккаунт разработчика. Локальный режим (без VPN) работает всегда.

## Использование

1. Открой TgWsProxy → **«Включить VPN»** → разреши профиль в системном окне. Значок «VPN» появится в статус-баре — теперь прокси живёт всегда, даже после перезагрузки (включи «Connect on Demand» в настройках VPN при желании).
2. **«Открыть в Telegram»** — Telegram добавит прокси 127.0.0.1:1443 (секрет хранится на телефоне).
3. Статистика и лог событий — в приложении; они обновляются из фонового процесса через App Group.

## Структура

```
TgWsProxy/
├── Shared/            # протокольное ядро (используется приложением и расширением)
│   ├── ProxyConstants.swift / ProxyCrypto.swift / MsgSplitter.swift
│   ├── WsUpstream.swift (WS + TCP-апстримы) / CfDomains.swift (CF-фолбэк + EventLog)
│   ├── ProxyServer.swift (listener + ClientBridge) / SharedStore.swift (App Group)
├── PacketTunnel/      # Packet Tunnel Provider (фоновый процесс VPN)
├── TgWsProxy/         # приложение: VPN-менеджер, UI, статистика
└── .github/workflows/build.yml
```

