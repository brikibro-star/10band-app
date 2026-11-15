import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tabItem { Label("Главная", systemImage: "house") }
                .tag(0)

            DevicesTab()
                .tabItem { Label("Устройства", systemImage: "dot.radiowaves.left.and.right") }
                .tag(1)

            DiagnosticTab()
                .tabItem { Label("Отчёт", systemImage: "doc.text.magnifyingglass") }
                .tag(2)

            KeyTab()
                .tabItem { Label("Ключ", systemImage: "key.horizontal") }
                .tag(3)
        }
        .tint(.blue)
    }
}

private struct HomeTab: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: bluetooth.isConnected ? "watchface.applewatch.case" : "watchface.applewatch.case")
                    .font(.system(size: 58))
                    .foregroundStyle(bluetooth.isConnected ? .green : .secondary)
                    .padding(.top, 30)

                Text("Xiaomi Smart Band 10")
                    .font(.title2.bold())

                VStack(spacing: 8) {
                    Text(bluetooth.status)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if let battery = bluetooth.batteryLevel {
                        Label("Заряд: \(battery)%", systemImage: "battery.100")
                            .font(.title3.weight(.semibold))
                    }
                    if bluetooth.isAuthenticated {
                        Label("Браслет авторизован", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                Button {
                    bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                } label: {
                    Label(bluetooth.isScanning ? "Остановить поиск" : "Найти браслет",
                          systemImage: bluetooth.isScanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if bluetooth.isConnected {
                    Button("Отключить браслет", role: .destructive) {
                        bluetooth.disconnect()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Band 10 Companion")
        }
    }
}

private struct DevicesTab: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if bluetooth.devices.isEmpty {
                        ContentUnavailableView("Устройств пока нет",
                                               systemImage: "dot.radiowaves.left.and.right",
                                               description: Text("На вкладке «Главная» нажмите «Найти браслет»."))
                    } else {
                        ForEach(bluetooth.devices) { device in
                            Button {
                                bluetooth.connect(to: device.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "watchface.applewatch.case")
                                        .font(.title2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).foregroundStyle(.primary)
                                        Text("RSSI: \(device.rssi) dBm")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Найденные BLE-устройства")
                } footer: {
                    Text("Выберите устройство, чтобы начать подключение. Держите браслет рядом с iPhone.")
                }
            }
            .navigationTitle("Устройства")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bluetooth.clearResults()
                        bluetooth.startScan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Обновить поиск")
                }
            }
        }
    }
}

private struct DiagnosticTab: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager
    @State private var reportURL: URL?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Записей журнала", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Text("\(bluetooth.logEntries.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(bluetooth.isConnected ? "Подключён" : "Не подключён")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Авторизация", systemImage: "checkmark.shield")
                        Spacer()
                        Text(bluetooth.isAuthenticated ? "Успешна" : "Не выполнена")
                            .foregroundStyle(.secondary)
                    }
                    if let battery = bluetooth.batteryLevel {
                        HStack {
                            Label("Заряд", systemImage: "battery.100")
                            Spacer()
                            Text("\(battery)%").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Состояние")
                }

                Section {
                    Button {
                        reportURL = bluetooth.exportLog()
                        showShare = reportURL != nil
                    } label: {
                        Label("Сформировать и отправить TXT-отчёт",
                              systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(bluetooth.logEntries.isEmpty)
                    Text("В отчёт входят события Bluetooth, ошибки подключения и найденные GATT-сервисы. Auth Key в файл не включается.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Экспорт отчёта")
                }

                Section {
                    if bluetooth.gattDetails.isEmpty {
                        Text("Данные появятся после успешного BLE-подключения.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bluetooth.gattDetails, id: \.self) { row in
                            Text(row)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("GATT-структура")
                }

                Section {
                    if bluetooth.logEntries.isEmpty {
                        Text("Журнал пока пуст. Запустите поиск и попытку подключения.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bluetooth.logEntries.suffix(100), id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Последние события")
                }
            }
            .navigationTitle("Диагностический отчёт")
            .sheet(isPresented: $showShare) {
                if let reportURL {
                    ShareSheetView(url: reportURL)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }
}

private struct ShareSheetView: View {
    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "doc.text")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("Отчёт готов")
                    .font(.title2.bold())
                Text("Файл Band10-BLE-Report.txt содержит диагностические события. Сохраните его в «Файлы» или отправьте сюда.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                ShareLink(item: url) {
                    Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .navigationTitle("Экспорт")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct KeyTab: View {
    @State private var authKey = ""
    @State private var message = ""
    @State private var keySaved = !Vault.importedBandKeys.isEmpty

    private var normalizedKey: String {
        authKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if keySaved {
                        Label("Ключ сохранён в Keychain", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Button("Заменить ключ") {
                            keySaved = false
                            authKey = ""
                            message = ""
                        }
                    } else {
                        SecureField("Вставьте 32 символа ключа", text: $authKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Сохранить ключ на iPhone", action: saveAuthKey)
                            .disabled(normalizedKey.count != 32 || !normalizedKey.allSatisfy(\.isHexDigit))
                    }
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Auth Key браслета")
                } footer: {
                    Text("Ключ хранится локально в защищённом хранилище iOS и не записывается в диагностический отчёт.")
                }
            }
            .navigationTitle("Ключ авторизации")
        }
    }

    private func saveAuthKey() {
        guard normalizedKey.count == 32, normalizedKey.allSatisfy(\.isHexDigit) else {
            message = "Нужен ключ из 32 шестнадцатеричных символов."
            return
        }
        Vault.importedBandKeys = [normalizedKey]
        guard Vault.importedBandKeys == [normalizedKey] else {
            keySaved = false
            message = "iOS не подтвердила сохранение в Keychain. Повторите попытку."
            return
        }
        authKey = ""
        keySaved = true
        message = "Ключ успешно сохранён."
    }
}
