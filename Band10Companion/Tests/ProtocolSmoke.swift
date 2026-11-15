import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let payload = Data([0x01, 0x02, 0xA5, 0x5A])
let encoded = MiFrame.encode(kind: MiFrame.kindData, seq: 7, payload: payload)
var buffer = [UInt8](encoded)
let packets = MiFrame.drain(&buffer)
expect(packets.count == 1, "one complete frame decoded")
expect(packets[0].kind == MiFrame.kindData, "frame kind preserved")
expect(packets[0].seq == 7, "frame sequence preserved")
expect(packets[0].payload == payload, "frame payload preserved")
expect(buffer.isEmpty, "decoder consumes complete frame")

// A malformed oversized frame header must not block the next valid frame.
let malformedHeader = Data([0xA5, 0xA5, MiFrame.kindData, 0x08, 0xFF, 0xFF, 0x00, 0x00])
var recoveryBuffer = [UInt8](malformedHeader + encoded)
let recovered = MiFrame.drain(&recoveryBuffer)
expect(recovered.count == 1, "decoder resynchronizes after oversized frame length")
expect(recovered[0].seq == 7, "valid frame after malformed header is preserved")

// A frame with a bad CRC is discarded without affecting the following valid frame.
var corrupted = [UInt8](encoded)
corrupted[8] ^= 0x01
var crcBuffer = corrupted + [UInt8](encoded)
let afterBadCRC = MiFrame.drain(&crcBuffer)
expect(afterBadCRC.count == 1, "decoder discards bad CRC frame")
expect(afterBadCRC[0].seq == 7, "valid frame after bad CRC is preserved")

var partial = [UInt8](encoded.prefix(6))
expect(MiFrame.drain(&partial).isEmpty, "partial frame is retained")
expect(!partial.isEmpty, "partial bytes remain buffered")

var writer = PBWriter()
writer.varint(1, 2)
writer.string(3, "Band10")
let decoded = PBMessage(writer.data)
expect(decoded?.varints[1] == 2, "protobuf varint round trip")
expect(decoded?.blobs[3] == Data("Band10".utf8), "protobuf string round trip")

let authKey = Data(repeating: 0x11, count: 16)
let phoneNonce = Data(repeating: 0x22, count: 16)
let watchNonce = Data(repeating: 0x33, count: 16)
let badProof = Data(repeating: 0x00, count: 32)
expect(MiAuth.confirmCommand(authKey: authKey, phoneNonce: phoneNonce,
                             watchNonce: watchNonce, watchHmac: badProof,
                             deviceName: "Band 10 Companion") == nil,
       "authentication rejects an invalid watch proof")

print("Protocol smoke tests passed.")
