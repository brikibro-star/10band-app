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
    @Published private(set) var isAuthenticated = false
    @Published private(set) var batteryLevel: Int?

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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "Bluetooth недоступен: \(stateDescription)"
            return
        }
        devices.removeAll()
        peripherals.removeAll()
        gattDetails.removeAll()
        isScanning = true
        status = "Поиск Xiaomi Smart Band 10…"
        central.scanForPeripherals(withServices: [bandService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if central.state == .poweredOn { status = "Поиск остановлен" }
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
            status = "Сначала импортируйте ключ из папки Mi Fitness."
            return
        }
        stopScan()
        resetSession()
        connectedPeripheral = peripheral
        status = "Подключение к браслету…"
        central.connect(peripheral, options: nil)
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
        status = "BLE-канал открыт. Запуск протокола…"
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
        status = "Проверка ключа браслета…"
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
        status = central.state == .poweredOn
            ? "Bluetooth готов. Можно искать браслет."
            : "Bluetooth: \(stateDescription)"
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
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
        status = "Соединение установлено. Поиск BLE-сервисов…"
        peripheral.delegate = self
        peripheral.discoverServices([bandService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Ошибка подключения: \(error?.localizedDescription ?? "нет подробностей")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetSession()
        status = "Соединение с браслетом разорвано."
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
