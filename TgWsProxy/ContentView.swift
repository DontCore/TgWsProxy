import SwiftUI
import UIKit

struct ContentView: View {
    @State private var running = false
    @State private var statusText = ""
    @State private var total = 0
    @State private var active = 0
    @State private var wsCount = 0
    @State private var fallbackCount = 0
    @State private var bytesUp = 0
    @State private var bytesDown = 0
    @State private var linkCopied = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        if running {
                            ProxyServer.shared.stop()
                        } else {
                            ProxyServer.shared.start()
                        }
                    } label: {
                        Label(running ? "Остановить прокси" : "Запустить прокси",
                              systemImage: running ? "stop.circle.fill" : "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(running ? .red : .green)

                    HStack {
                        Text("Статус")
                        Spacer()
                        Text(statusText).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Локальный MTProto-прокси")
                } footer: {
                    Text("Пока приложение на экране. MVP без фоновой работы: Network Extension (VPN-профиль) — следующий этап.")
                }

                Section("Статистика") {
                    statRow("Активных подключений", "\(active)")
                    statRow("Всего подключений", "\(total)")
                    statRow("Через WebSocket", "\(wsCount)")
                    statRow("Через TCP-фолбэк", "\(fallbackCount)")
                    statRow("Отдано", ProxyStats.shared.humanBytes(bytesUp))
                    statRow("Получено", ProxyStats.shared.humanBytes(bytesDown))
                }

                Section("Подключить Telegram") {
                    Button {
                        if let url = URL(string: ProxyServer.proxyLink) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Открыть в Telegram", systemImage: "paperplane.fill")
                    }
                    Button {
                        UIPasteboard.general.string = ProxyServer.proxyLink
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { linkCopied = false }
                    } label: {
                        Label(linkCopied ? "Скопировано!" : "Скопировать ссылку прокси", systemImage: "doc.on.doc")
                    }
                    Text("Нажми «Открыть в Telegram» и подтверди прокси — Telegram подключится к 127.0.0.1 напрямую, без внешних серверов.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Трафик Telegram идёт в WebSocket-эндпоинты веб-клиента Telegram (kws*.web.telegram.org) — для провайдера это обычный веб-телеграм. Порт ядра tg-ws-proxy (Flowseal, MIT).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Как это работает")
                }
            }
            .navigationTitle("TgWsProxy")
        }
        .onReceive(timer) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func refresh() {
        running = ProxyServer.shared.isRunning
        statusText = ProxyServer.shared.statusText
        let s = ProxyStats.shared
        total = s.connectionsTotal
        active = s.connectionsActive
        wsCount = s.connectionsWs
        fallbackCount = s.connectionsFallback
        bytesUp = s.bytesUp
        bytesDown = s.bytesDown
    }
}
