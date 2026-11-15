import Foundation
import Combine
import CoreBluetooth
import Security

struct BandDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor
final class BandBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var devices: [BandDevice] = []
    @Published private(set) var gattDetails: [String] = []
    @Published private(set) var status = "Проверка Bluetooth…"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var logEntries: [String] = []

    private let bandService = CBUUID(string: "FE95")
    private let notifyUUID = CBUUID(string: "005E")
    private let writeUUID = CBUUID(string: "005F")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveBuffer: [UInt8] = []
    private var writeQueue: [Data] = []
    private var sequence: UInt8 = 0
    private var phoneNonce = Data()
    private var sessionKeys: MiAuth.SessionKeys?
    private var candidateKeys: [Data] = []
    private var keyIndex = 0
    private var connectionTimeout: DispatchWorkItem?
    private var connectionTimedOut = false

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logEntries.append("[\\(stamp)] \\(message)")
        if logEntries.count > 1500 { logEntries.removeFirst(logEntries.count - 1500) }
    }

    func exportLog() -> URL? {
        let header = "Band 10 Companion BLE diagnostic report\\nDevice: iPhone / iOS\\nCentral state: \\(stateDescription)\\nStatus: \\(status)\\nConnected: \\(isConnected)\\nAuthenticated: \\(isAuthenticated)\\n\\n"
        let content = header + logEntries.joined(separator: "\\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Band10-BLE-Report-\\(Int(Date().timeIntervalSince1970)).txt")
        do { try content.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { log("LOG EXPORT ERROR: \\(error.localizedDescription)"); return nil }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        log("SCAN requested; central state=\\(central.state.rawValue) (\\(stateDescription))")
        guard central.state == .poweredOn else {
            status = "Bluetooth недоступен: \(stateDescription)"
            return
        }
        devices.removeAll()
        peripherals.removeAll()
        gattDetails.removeAll()
        isScanning = true
        status = "Поиск Xiaomi Smart Band 10…"
        log("SCAN started; service filter=\\(bandService.uuidString)")
        central.scanForPeripherals(withServices: [bandService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if central.state == .poweredOn { status = "Поиск остановлен" }
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        status = "Отключение от браслета…"
        central.cancelPeripheralConnection(peripheral)
    }

    func clearResults() {
        devices.removeAll()
        gattDetails.removeAll()
    }

    func connect(to id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        candidateKeys = Vault.importedBandKeys.compactMap { hex in
            guard hex.count == 32 else { return nil }
            return BandKey(hex: hex).data
        }
        guard !candidateKeys.isEmpty else {
            status = "Сначала вставьте и сохраните ключ авторизации в разделе выше."
            return
        }
        stopScan()
        if let current = connectedPeripheral { central.cancelPeripheralConnection(current) }
        resetSession()
        connectionTimeout?.cancel()
        connectionTimedOut = false
        connectedPeripheral = peripheral
        status = "Подключение к браслету…"
        central.connect(peripheral, options: nil)

        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  !self.isConnected else { return }
            self.log("CONNECT TIMEOUT after 15s; peripheral id=\\(peripheral.identifier.uuidString); central state=\\(self.central.state.rawValue)")\n            self.connectionTimedOut = true
            self.status = "Браслет не ответил за 15 секунд. Проверьте Bluetooth и повторите поиск."
            self.central.cancelPeripheralConnection(peripheral)
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private var stateDescription: String {
        switch central.state {
        case .poweredOn: return "включён"
        case .poweredOff: return "выключен"
        case .unauthorized: return "нет разрешения"
        case .unsupported: return "не поддерживается"
        case .resetting: return "перезапускается"
        case .unknown: return "неизвестное состояние"
        @unknown default: return "неизвестное состояние"
        }
    }

    private func resetSession() {
        isAuthenticated = false
        batteryLevel = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        receiveBuffer.removeAll()
        writeQueue.removeAll()
        sequence = 0
        phoneNonce = Data()
        sessionKeys = nil
        keyIndex = 0
    }

    private func startSession() {
        log("PROTOCOL session start; notify=\\(notifyCharacteristic?.uuid.uuidString ?? "nil"); write=\\(writeCharacteristic?.uuid.uuidString ?? "nil")")\n        status = "BLE-канал открыт. Запуск протокола…"
        sendFrame(MiFrame.encode(kind: MiFrame.kindSessionConfig, seq: 0,
                                 payload: MiFrame.startSessionPayload))
    }

    private func startAuthentication() {
        var nonce = Data(count: 16)
        let result = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            status = "Не удалось создать случайный ключ сеанса."
            return
        }
        phoneNonce = nonce
        log("AUTH started; candidate key count=\\(candidateKeys.count); key bytes not logged")\n        status = "Проверка ключа браслета…"
        sendCommand(MiAuth.nonceCommand(phoneNonce: nonce), encrypted: false)
    }

    private func sendCommand(_ protobuf: Data, encrypted: Bool) {
        var body = protobuf
        if encrypted, let sessionKeys {
            body = MiCrypto.ctr(key: sessionKeys.encryptionKey, protobuf)
        }
        let payload = Data([0x01, encrypted ? 0x02 : 0x01]) + body
        let frame = MiFrame.encode(kind: MiFrame.kindData, seq: sequence, payload: payload)
        sequence &+= 1
        sendFrame(frame)
    }

    private func sendFrame(_ frame: Data) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            writeQueue.append(frame.subdata(in: offset..<end))
            offset = end
        }
        pumpWrites()
    }

    private func pumpWrites() {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        while !writeQueue.isEmpty && peripheral.canSendWriteWithoutResponse {
            let data = writeQueue.removeFirst()
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    private func receive(_ chunk: Data) {
        receiveBuffer.append(contentsOf: chunk)
        for packet in MiFrame.drain(&receiveBuffer) {
            switch packet.kind {
            case MiFrame.kindSessionConfig:
                if phoneNonce.isEmpty { startAuthentication() }
            case MiFrame.kindData:
                sendFrame(MiFrame.encode(kind: MiFrame.kindAck, seq: packet.seq, payload: Data()))
                decode(packet)
            case MiFrame.kindNack:
                status = "Браслет запросил повтор передачи (NACK \(packet.seq))."
            default:
                break
            }
        }
    }

    private func decode(_ packet: MiFrame.Packet) {
        guard packet.payload.count >= 2 else { return }
        let channel = packet.payload[0] & 0x0F
        let opcode = packet.payload[1]
        guard channel == 1 else { return }
        var body = Data(packet.payload.dropFirst(2))
        if opcode == 2 {
            guard let sessionKeys else { return }
            body = MiCrypto.ctr(key: sessionKeys.decryptionKey, body)
        }
        guard let command = PBMessage(body) else { return }
        handle(command)
    }

    private func handle(_ command: PBMessage) {
        let type = command.varints[1] ?? 0
        let subtype = command.varints[2] ?? 0

        if type == MiAuth.commandTypeAuth && subtype == MiAuth.subtypeNonce {
            guard let verify = command.message(3)?.message(31),
                  let watchNonce = verify.blobs[1],
                  let watchHmac = verify.blobs[2] else {
                status = "Браслет не прислал данные авторизации. Закройте Mi Fitness и повторите."
                return
            }
            while keyIndex < candidateKeys.count {
                if let result = MiAuth.confirmCommand(authKey: candidateKeys[keyIndex],
                                                      phoneNonce: phoneNonce,
                                                      watchNonce: watchNonce,
                                                      watchHmac: watchHmac,
                                                      deviceName: "Band 10 Companion") {
                    sessionKeys = result.keys
                    status = "Ключ принят. Завершение авторизации…"
                    sendCommand(result.command, encrypted: false)
                    return
                }
                keyIndex += 1
            }
            status = "Ключ не подошёл. Проверьте, что импортировали ключ именно этого браслета."
            return
        }

        if type == MiAuth.commandTypeAuth && subtype == MiAuth.subtypeAuth {
            isAuthenticated = true
            status = "Браслет авторизован. Запрашиваю заряд батареи…"
            sendCommand(MiAuth.batteryCommand(), encrypted: true)
            return
        }

        if type == 2 && subtype == 1, let level = MiAuth.batteryLevel(command) {
            batteryLevel = Int(level)
            status = "Подключено и авторизовано. Заряд: \(level)%."
        }
    }
}

extension BandBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CENTRAL state changed: raw=\\(central.state.rawValue), description=\\(stateDescription), authorization=\\(CBManager.authorization.rawValue)")\n        status = central.state == .poweredOn
            ? "Bluetooth готов. Можно искать браслет."
            : "Bluetooth: \(stateDescription)"
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String\n        log("DISCOVER id=\\(peripheral.identifier.uuidString); name=\\(peripheral.name ?? advertisedName ?? "nil"); RSSI=\\(RSSI); connectable=\\(advertisementData[CBAdvertisementDataIsConnectable] ?? "unknown"); serviceUUIDs=\\((advertisementData[CBAdvertisementDataServiceUUIDs] as? [CBUUID])?.map(\\.uuidString).joined(separator: ",") ?? "none")")
        let name = peripheral.name ?? advertisedName ?? "Xiaomi BLE device"
        peripherals[peripheral.identifier] = peripheral
        let device = BandDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            devices.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        connectionTimedOut = false
        isConnected = true
        status = "Соединение установлено. Поиск BLE-сервисов…"
        peripheral.delegate = self
        peripheral.discoverServices([bandService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        isConnected = false
        connectedPeripheral = nil
        status = "Ошибка подключения: \(error?.localizedDescription ?? "нет подробностей")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        resetSession()
        isConnected = false
        connectedPeripheral = nil
        if connectionTimedOut {
            status = "Тайм-аут BLE: браслет не завершил подключение за 15 секунд."
            connectionTimedOut = false
        } else {
            status = "Соединение с браслетом разорвано."
        }
    }
}

extension BandBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Ошибка чтения сервисов: \(error.localizedDescription)"
            return
        }
        for service in peripheral.services ?? [] {
            gattDetails.append("SERVICE  \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics([notifyUUID, writeUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            status = "Ошибка чтения характеристик: \(error.localizedDescription)"
            return
        }
        for characteristic in service.characteristics ?? [] {
            let properties = characteristic.properties
            var flags: [String] = []
            if properties.contains(.read) { flags.append("read") }
            if properties.contains(.write) { flags.append("write") }
            if properties.contains(.writeWithoutResponse) { flags.append("write-no-response") }
            if properties.contains(.notify) { flags.append("notify") }
            if properties.contains(.indicate) { flags.append("indicate") }
            gattDetails.append("CHAR  \(characteristic.uuid.uuidString) [\(flags.joined(separator: ", "))]")
            if characteristic.uuid == notifyUUID { notifyCharacteristic = characteristic }
            if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
        }
        guard let notifyCharacteristic, writeCharacteristic != nil else {
            status = "Не найдены характеристики FE95/005E/005F."
            return
        }
        status = "BLE-характеристики найдены. Включаю уведомления…"
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        if let error {
            status = "Не удалось включить уведомления: \(error.localizedDescription)"
        } else if characteristic.isNotifying {
            startSession()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            status = "Ошибка приёма BLE: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == notifyUUID, let value = characteristic.value else { return }
        receive(value)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}
