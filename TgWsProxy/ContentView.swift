import SwiftUI
import UIKit
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpn = VPNManager.shared
    @State private var localRunning = false
    @State private var localStatus = ""
    @State private var stats: [String: Int] = [:]
    @State private var logLines: [String] = []
    @State private var linkCopied = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        vpn.toggle()
                    } label: {
                        Label(vpn.status == .connected ? "Выключить VPN" : "Включить VPN (фон 24/7)",
                              systemImage: vpn.status == .connected ? "stop.circle.fill" : "bolt.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vpn.status == .connected ? .red : .green)

                    HStack {
                        Text("VPN")
                        Spacer()
                        Text(vpn.statusText).foregroundStyle(.secondary)
                    }
                    if let error = vpn.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Фоновый режим (VPN-профиль)")
                } footer: {
                    Text("Туннель держит прокси живым круглосуточно, реальный трафик не перехватывается. Требует энтайтмент Network Extension — на бесплатной подписи iOS отвечает «permission denied» (так и задумано Apple): тогда пользуйся режимом 24/7 ниже или платным аккаунтом разработчика.")
                }

                Section {
                    Button {
                        if localRunning {
                            ProxyServer.shared.stop()
                            BackgroundKeepAlive.shared.stop()
                            UIApplication.shared.isIdleTimerDisabled = false
                        } else {
                            ProxyServer.shared.start()
                            BackgroundKeepAlive.shared.start()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                    } label: {
                        Label(localRunning ? "Остановить режим 24/7" : "Запустить режим 24/7",
                              systemImage: localRunning ? "stop.circle" : "infinity.circle")
                    }
                    HStack {
                        Text("Локальный режим")
                        Spacer()
                        Text(localStatus).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Режим 24/7 (без VPN)")
                } footer: {
                    Text("Играет неслышимую тишину, чтобы iOS не замораживала приложение — прокси живёт круглосуточно, экран можно блокировать. Тратит немного батареи. Без VPN и энтайтментов — работает на бесплатной подписи.")
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
                    Text("Telegram должен использовать прокси 127.0.0.1:\(ProxyConst.listenPort) — ссылка добавляет его автоматически.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Статистика") {
                    statRow("Активных подключений", "\(stats["active"] ?? 0)")
                    statRow("Всего подключений", "\(stats["total"] ?? 0)")
                    statRow("Через WebSocket", "\(stats["ws"] ?? 0)")
                    statRow("Через TCP-фолбэк", "\(stats["fallback"] ?? 0)")
                    statRow("Отдано", ProxyStats.shared.humanBytes(stats["up"] ?? 0))
                    statRow("Получено", ProxyStats.shared.humanBytes(stats["down"] ?? 0))
                }

                Section {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if logLines.isEmpty {
                                Text("— пусто —").foregroundStyle(.secondary)
                            }
                            ForEach(Array(logLines.enumerated().reversed()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 150)
                } header: {
                    Text("Лог (VPN + прокси)")
                }
            }
            .navigationTitle("TgWsProxy")
        }
        .onReceive(timer) { _ in refresh() }
        .onAppear {
            vpn.loadOrCreate()
            refresh()
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func refresh() {
        localRunning = ProxyServer.shared.isRunning
        localStatus = ProxyServer.shared.statusText
        stats = SharedStore.defaults.dictionary(forKey: "stats") as? [String: Int] ?? [:]
        logLines = SharedStore.defaults.stringArray(forKey: "eventLog") ?? []
    }
}
