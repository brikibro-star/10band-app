import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

private struct DevicesTab: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Xiaomi Smart Band 10")
                            .font(.system(size: 20, weight: .bold))
                        Text(bluetooth.status)
                            .font(.system(size: 14))
                            .foregroundStyle(bluetooth.isConnected ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    HStack(spacing: 8) {
                        Button {
                            bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                        } label: {
                            Label(bluetooth.isScanning ? "Стоп" : "Найти браслет",
                                  systemImage: bluetooth.isScanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        if bluetooth.isConnected || bluetooth.isConnecting {
                            Button("Отключить", role: .destructive) { bluetooth.disconnect() }
                                .font(.system(size: 14))
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                        }
                    }

                    HStack {
                        Text("Найденные браслеты").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("\(bluetooth.devices.count)")
                            .font(.system(size: 13, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if bluetooth.devices.isEmpty {
                        ContentUnavailableView(
                            "Браслет пока не найден",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text("Нажмите «Найти браслет». Отображаются только устройства с идентификатором Xiaomi FE95.")
                                .font(.system(size: 13))
                        )
                    } else {
                        LazyVStack(spacing: 9) {
                            ForEach(bluetooth.devices) { device in deviceCard(device) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Браслет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bluetooth.clearResults()
                        bluetooth.startScan()
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Обновить поиск")
                }
            }
        }
    }

    private func deviceCard(_ device: BandDevice) -> some View {
        let isActive = bluetooth.activePeripheralID == device.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "watchface.applewatch.case")
                    .font(.system(size: 25))
                    .foregroundStyle(isActive ? .green : .blue)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name == "Xiaomi BLE device" ? "Xiaomi Smart Band 10" : device.name)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Сигнал: \(device.rssi) dBm")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(isActive ? bluetooth.status : "Обнаружен • готов к подключению")
                        .font(.system(size: 12))
                        .foregroundStyle(isActive && bluetooth.isConnected ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if isActive && bluetooth.isAuthenticated {
                Label("Авторизован", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    bluetooth.connect(to: device.id)
                } label: {
                    Label(isActive && bluetooth.isConnecting ? "Подключение…" : "Подключить",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(bluetooth.isConnecting || (isActive && bluetooth.isConnected))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

private struct DiagnosticTab: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Состояние") {
                    statusRow("Bluetooth", value: bluetooth.isConnected ? "Подключён" : (bluetooth.isConnecting ? "Подключение…" : "Не подключён"))
                    statusRow("Авторизация", value: bluetooth.isAuthenticated ? "Выполнена" : "Не выполнена")
                    statusRow("Заряд", value: bluetooth.batteryLevel.map { "\($0)%" } ?? "Нет данных")
                    statusRow("Записей журнала", value: "\(bluetooth.logEntries.count)")
                }

                Section("GATT — характеристики") {
                    if bluetooth.gattDetails.isEmpty {
                        Text("Пока нет данных. Характеристики появятся после успешного BLE-подключения.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(bluetooth.gattDetails, id: \.self) { row in
                            Text(row)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 2)
                        }
                    }
                }

                Section("Отчёт") {
                    Button {
                        UIPasteboard.general.string = bluetooth.diagnosticReport
                        copied = true
                    } label: {
                        Label(copied ? "Отчёт скопирован" : "Скопировать весь отчёт",
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .disabled(bluetooth.logEntries.isEmpty)
                    Text("Полный отчёт сразу копируется в буфер обмена. Вставьте его сюда сообщением. Auth Key не включается.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Последние события") {
                    if bluetooth.logEntries.isEmpty {
                        Text("Журнал пока пуст.")
                            .font(.system(size: 12))
                    } else {
                        ForEach(bluetooth.logEntries.suffix(80), id: \.self) { entry in
                            Text(entry)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .listStyle(.insetGrouped)
            .navigationTitle("Отчёт")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
    }
}

private struct KeyTab: View {
    @State private var authKey = ""
    @State private var message = ""
    @State private var keySaved = !Vault.importedBandKeys.isEmpty
    @State private var showingFolderPicker = false
    @State private var showingZipPicker = false
    @State private var importedDeviceNames: [String] = []

    private var normalizedKey: String {
        authKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Автоматическое получение ключа") {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label("Выбрать папку Mi Fitness", systemImage: "folder")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Button {
                        showingZipPicker = true
                    } label: {
                        Label("Выбрать ZIP-архив", systemImage: "doc.zipper")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text("Выберите папку Mi Fitness в приложении «Файлы» или ZIP-архив этой папки. Приложение найдёт encryptKey для Smart Band 10 и сохранит его в защищённое хранилище.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !importedDeviceNames.isEmpty {
                        ForEach(importedDeviceNames, id: \.self) { name in
                            Label(name, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        }
                    } else if keySaved {
                        Label("Ключ сохранён в Keychain", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                    }
                }

                Section("Ручной ввод — запасной способ") {
                    if keySaved {
                        Button("Заменить ключ вручную") {
                            keySaved = false
                            authKey = ""
                            message = ""
                        }
                        .font(.system(size: 14))
                    } else {
                        SecureField("32 шестнадцатеричных символа", text: $authKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                        Button("Сохранить ключ на iPhone", action: saveAuthKey)
                            .font(.system(size: 14))
                            .disabled(normalizedKey.count != 32 || !normalizedKey.allSatisfy(\.isHexDigit))
                    }
                }

                if !message.isEmpty {
                    Section("Результат") {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                Section("Важно") {
                    Text("Ключ извлекается из локальных файлов Mi Fitness, а не считывается по Bluetooth. После первого импорта приложение будет автоматически использовать сохранённый ключ при подключении. Не отвязывайте и не сбрасывайте браслет: это может изменить ключ.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Ключ остаётся на iPhone, не включается в диагностический отчёт и не отправляется на сервер.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Ключ")
            .navigationBarTitleDisplayMode(.inline)
            // Separate pickers: iOS Files reliably enables “Open” for a folder
            // when the allowed type is folder-only, rather than a mixed folder/ZIP list.
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                importMiFitness(result)
            }
            .fileImporter(
                isPresented: $showingZipPicker,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                importMiFitness(result)
            }
        }
    }

    private func importMiFitness(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let keys = try KeyLoader.load(from: url)
            let hexKeys = keys.map(\.hex)
            guard !hexKeys.isEmpty else {
                message = "В выбранных файлах не найден ключ Smart Band 10."
                return
            }
            let expectedKeys = Array(NSOrderedSet(array: hexKeys)) as? [String] ?? []
            Vault.importedBandKeys = hexKeys
            guard Vault.importedBandKeys == expectedKeys else {
                message = "Не удалось сохранить все найденные ключи в Keychain."
                keySaved = false
                return
            }
            keySaved = true
            importedDeviceNames = keys.map { "\($0.name)\($0.macSuffix.map { " • …\($0)" } ?? "")" }
            message = "Найдено ключей: \(keys.count). Они сохранены. Теперь подключайтесь к браслету."
        } catch {
            message = "Не удалось извлечь ключ. \(error.localizedDescription)"
            keySaved = !Vault.importedBandKeys.isEmpty
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
        importedDeviceNames = []
        message = "Ключ успешно сохранён. Переподключите браслет для авторизации."
    }
}
