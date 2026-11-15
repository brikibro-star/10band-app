import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager
    @State private var authKey = ""
    @State private var keyMessage = ""
    @State private var keySaved = !Vault.importedBandKeys.isEmpty

    private var normalizedKey: String {
        authKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("XIAOMI SMART BAND 10")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    if keySaved {
                        Label("Ключ активен", systemImage: "checkmark.shield.fill")
                            .font(.caption2.weight(.medium)).foregroundStyle(.green)
                    }
                    if bluetooth.isAuthenticated {
                        Label("Авторизация успешна", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if let battery = bluetooth.batteryLevel {
                        Text("Заряд браслета: \(battery)%")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(bluetooth.status)
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                HStack {
                    Button(bluetooth.isScanning ? "Остановить поиск" : "Найти браслет") {
                        bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    if bluetooth.isConnected {
                        Button("Отключить") { bluetooth.disconnect() }
                            .buttonStyle(.bordered)
                    }
                    Button("Очистить") { bluetooth.clearResults() }
                        .buttonStyle(.bordered)
                }

                List {
                    if !keySaved {
                    Section("Ключ авторизации браслета") {
                        SecureField("Вставьте 32 символа ключа", text: $authKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Сохранить ключ на iPhone") {
                            saveAuthKey()
                        }
                        .disabled(normalizedKey.count != 32 || !normalizedKey.allSatisfy(\.isHexDigit))
                        if keySaved {
                            Label("Ключ сохранён в Keychain", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                        }
                        if !keyMessage.isEmpty {
                            Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Вставьте ключ из текстового файла. Он хранится только на этом iPhone и не отправляется в интернет.")
                            .font(.caption).foregroundStyle(.secondary)
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
                                        Text(device.name).foregroundStyle(.primary)
                                        Text("RSSI: \(device.rssi) dBm")
                                            .font(.caption).foregroundStyle(.secondary)
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
                                Text(row).font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Band 10 Companion")
        }
    }

    private func saveAuthKey() {
        guard normalizedKey.count == 32, normalizedKey.allSatisfy(\.isHexDigit) else {
            keyMessage = "Нужен ключ из 32 шестнадцатеричных символов."
            return
        }
        Vault.importedBandKeys = [normalizedKey]
        guard Vault.importedBandKeys == [normalizedKey] else {
            keySaved = false
            keyMessage = "iOS не подтвердила сохранение в Keychain. Повторите попытку."
            return
        }
        authKey = ""
        keySaved = true
        keyMessage = "Ключ успешно сохранён. Теперь можно искать браслет."
    }
}

// Build refresh: hide saved auth-key form and show active indicator.
