import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BandBluetoothManager
    @State private var pickerTarget: PickerTarget?
    @State private var importedKeys: [BandKey] = []
    @State private var keyImportMessage = "Импортируйте ZIP-архив Mi Fitness или папку с данными."

    private enum PickerTarget: String, Identifiable {
        case folder, manifest, archive
        var id: String { rawValue }
        var contentType: UTType {
            switch self {
            case .folder: return .folder
            case .manifest: return UTType(filenameExtension: "sqlite") ?? .data
            case .archive: return UTType(filenameExtension: "zip") ?? .data
            }
    }
    }

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
                        Button("Отключить") { bluetooth.disconnect() }
                            .buttonStyle(.bordered)
                    }

                    Button("Очистить") { bluetooth.clearResults() }
                        .buttonStyle(.bordered)
                }

                List {
                    Section("Авторизация Mi Fitness") {
                        Button {
                            pickerTarget = .folder
                        } label: {
                            Label("Выбрать папку Mi Fitness", systemImage: "folder")
                        }
                        Button {
                            pickerTarget = .archive
                        } label: {
                            Label("Импортировать ZIP-архив Mi Fitness", systemImage: "doc.zipper")
                        }
                        Button {
                            pickerTarget = .manifest
                        } label: {
                            Label("Выбрать manifest.sqlite", systemImage: "doc")
                        }
                        Text(keyImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                                        Text(device.name).foregroundStyle(.primary)
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
            .sheet(item: $pickerTarget) { target in
                SystemDocumentPicker(contentType: target.contentType) { result in
                    pickerTarget = nil
                    switch result {
                    case .success(let url):
                        importKeys(from: url)
                    case .failure(let error):
                        keyImportMessage = "Выбор отменён или не удался: \(error.localizedDescription)"
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func importKeys(from url: URL) {
        do {
            let keys = try KeyLoader.load(from: url)
            guard !keys.isEmpty else {
                keyImportMessage = "В выбранном месте ключ не найден."
                return
            }
            let imported = keys.map(\.hex)
            Vault.importedBandKeys = imported
            guard Vault.importedBandKeys == imported else {
                keyImportMessage = "Ключ найден, но iOS не подтвердила его сохранение в Keychain. Проверьте настройки устройства и повторите импорт."
                return
            }
            importedKeys = keys
            keyImportMessage = "Ключ обычного Smart Band 10 найден и сохранён в защищённом хранилище iPhone."
        } catch {
            keyImportMessage = "Ошибка импорта: \(error.localizedDescription)"
        }
    }
}

private struct SystemDocumentPicker: UIViewControllerRepresentable {
    let contentType: UTType
    let completion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [contentType], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(completion: @escaping (Result<URL, Error>) -> Void) {
            self.completion = completion
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            completion(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.failure(NSError(domain: "Band10Companion.DocumentPicker", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Выбор отменён"])))
        }
    }
}
