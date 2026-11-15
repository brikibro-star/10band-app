import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DevicesTab()
                .tabItem { Label("Браслет", systemImage: "watchface.applewatch.case") }
            DiagnosticTab()
                .tabItem { Label("Отчёт", systemImage: "doc.text.magnifyingglass") }
            KeyTab()
                .tabItem { Label("Ключ", systemImage: "key.horizontal") }
        }
        .tint(.blue)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

private struct DevicesTab: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Xiaomi Smart Band 10")
                            .font(.title2.weight(.bold))
                        Text(bluetooth.status)
                            .font(.body)
                            .foregroundStyle(bluetooth.isConnected ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    HStack(spacing: 10) {
                        Button {
                            bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                        } label: {
                            Label(bluetooth.isScanning ? "Остановить поиск" : "Найти браслет",
                                  systemImage: bluetooth.isScanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if bluetooth.isConnected || bluetooth.isConnecting {
                            Button("Отключить", role: .destructive) {
                                bluetooth.disconnect()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }

                    HStack {
                        Text("Найденные браслеты")
                            .font(.headline)
                        Spacer()
                        Text("\(bluetooth.devices.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if bluetooth.devices.isEmpty {
                        ContentUnavailableView(
                            "Браслет пока не найден",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text("Нажмите «Найти браслет». В списке будут отображаться только устройства с рекламным идентификатором Xiaomi FE95.")
                        )
                        .padding(.top, 12)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(bluetooth.devices) { device in
                                deviceCard(device)
                            }
                        }
                    }

                    if bluetooth.isAuthenticated {
                        Label("Авторизация выполнена", systemImage: "checkmark.seal.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.green)
                    } else if bluetooth.isConnected {
                        Label("Bluetooth подключён; авторизация ещё не завершена", systemImage: "lock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Устройства")
            .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private func deviceCard(_ device: BandDevice) -> some View {
        let isActive = bluetooth.activePeripheralID == device.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "watchface.applewatch.case")
                    .font(.system(size: 30))
                    .foregroundStyle(isActive ? .green : .blue)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.name == "Xiaomi BLE device" ? "Xiaomi Smart Band 10 (FE95)" : device.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Сигнал: \(device.rssi) dBm")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(isActive ? bluetooth.status : "Обнаружен • готов к подключению")
                        .font(.subheadline)
                        .foregroundStyle(isActive && bluetooth.isConnected ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }

            if isActive && bluetooth.isAuthenticated {
                Label("Авторизован", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    bluetooth.connect(to: device.id)
                } label: {
                    Label(isActive && bluetooth.isConnecting ? "Подключение…" : "Подключить",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(bluetooth.isConnecting || (isActive && bluetooth.isConnected))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isActive ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
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
                Section("Состояние") {
                    statusRow("Bluetooth", value: bluetooth.isConnected ? "Подключён" : (bluetooth.isConnecting ? "Подключение…" : "Не подключён"))
                    statusRow("Авторизация", value: bluetooth.isAuthenticated ? "Выполнена" : "Ожидает Auth Key / ответа браслета")
                    statusRow("Заряд", value: bluetooth.batteryLevel.map { "\($0)%" } ?? "Нет данных")
                    statusRow("Записей журнала", value: "\(bluetooth.logEntries.count)")
                }

                Section("GATT — все обнаруженные характеристики") {
                    if bluetooth.gattDetails.isEmpty {
                        Text("Данные появятся после подключения и чтения GATT.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(bluetooth.gattDetails, id: \.self) { row in
                            Text(row)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 3)
                        }
                    }
                }

                Section("Экспорт") {
                    Button {
                        reportURL = bluetooth.exportLog()
                        showShare = reportURL != nil
                    } label: {
                        Label("Сформировать TXT-отчёт", systemImage: "square.and.arrow.up")
                    }
                    .disabled(bluetooth.logEntries.isEmpty)
                    Text("В отчёт входят события Bluetooth, ошибки и полный список GATT-характеристик. Auth Key не экспортируется.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Последние события") {
                    if bluetooth.logEntries.isEmpty {
                        Text("Журнал пока пуст.")
                    } else {
                        ForEach(bluetooth.logEntries.suffix(120), id: \.self) { entry in
                            Text(entry)
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
            .font(.body)
            .listStyle(.insetGrouped)
            .navigationTitle("Диагностика")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showShare) {
                if let reportURL {
                    ShareSheetView(url: reportURL)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
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
                Text("Band10-BLE-Report.txt содержит диагностические события и полный список найденных GATT-характеристик.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Section("Auth Key браслета") {
                    if keySaved {
                        Label("Ключ сохранён в Keychain", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Button("Заменить ключ") {
                            keySaved = false
                            authKey = ""
                            message = ""
                        }
                    } else {
                        SecureField("32 шестнадцатеричных символа", text: $authKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 16, design: .monospaced))
                        Button("Сохранить ключ на iPhone", action: saveAuthKey)
                            .disabled(normalizedKey.count != 32 || !normalizedKey.allSatisfy(\.isHexDigit))
                    }
                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Зачем нужен ключ") {
                    Text("Bluetooth-подключение и авторизация — разные этапы. Без Auth Key приложение может обнаружить браслет и прочитать его GATT-структуру, но защищённый обмен данными и получение заряда могут быть недоступны.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Text("Ключ хранится локально в защищённом хранилище iOS и не записывается в диагностический отчёт.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Авторизация")
            .navigationBarTitleDisplayMode(.inline)
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
        message = "Ключ успешно сохранён. Переподключите браслет для авторизации."
    }
}
