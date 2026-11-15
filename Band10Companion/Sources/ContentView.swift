import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager
    @State private var showingKeyFolderPicker = false
    @State private var importedKeys: [BandKey] = []
    @State private var keyImportMessage = "Выбери папку Mi Fitness или файл manifest.sqlite"

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 5) {
                    Text("XIAOMI SMART BAND 10")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    if bluetooth.isAuthenticated {
                        Label("Авторизация успешна", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let battery = bluetooth.batteryLevel {
                        Text("Заряд браслета: \(battery)%")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(bluetooth.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                HStack {
                    Button(bluetooth.isScanning ? "Остановить поиск" : "Найти браслет") {
                        bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                    }
                    .buttonStyle(.borderedProminent)

                    if bluetooth.isConnected {
                        Button("Отключить") {
                            bluetooth.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Очистить") {
                        bluetooth.clearResults()
                    }
                    .buttonStyle(.bordered)
                }

                List {
                    Section("Авторизация Mi Fitness") {
                        Button {
                            showingKeyFolderPicker = true
                        } label: {
                            Label("Импортировать ключ из Mi Fitness", systemImage: "key.horizontal")
                        }
                        if !keyImportMessage.isEmpty {
                            Text(keyImportMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(importedKeys.enumerated()), id: \.offset) { _, key in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key.name)
                                    Text(key.masked)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    Section("Найденные устройства") {
                        if bluetooth.devices.isEmpty {
                            Text("Нажмите «Найти браслет». Держите браслет рядом с iPhone.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(bluetooth.devices) { device in
                            Button {
                                bluetooth.connect(to: device.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name)
                                            .foregroundStyle(.primary)
                                        Text("RSSI: \(device.rssi) dBm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                }
                            }
                        }
                    }

                    Section("GATT-структура подключённого устройства") {
                        if bluetooth.gattDetails.isEmpty {
                            Text("После подключения здесь появятся UUID сервисов и характеристик.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(bluetooth.gattDetails, id: \.self) { row in
                                Text(row)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Band 10 Companion")
            .fileImporter(
                isPresented: $showingKeyFolderPicker,
                allowedContentTypes: [.folder, .data],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let selectedURL = try result.get().first else { return }
                    let keys = try KeyLoader.load(from: selectedURL)
                    guard !keys.isEmpty else {
                        keyImportMessage = "В выбранном месте Mi Fitness ключ браслета не найден."
                        return
                    }
                    importedKeys = keys
                    Vault.importedBandKeys = keys.map(\.hex)
                    keyImportMessage = "Найдено ключей: \(keys.count). Секреты сохранены в Keychain."
                } catch {
                    keyImportMessage = "Ошибка импорта: \(error.localizedDescription)"
                }
            }
        }
    }
}
