import Foundation
import IOBluetooth

// Classic Serial Port Profile transport for the Coibeu WKDY-81X.
// Python on macOS has no AF_BLUETOOTH, so the CUPS bridge calls this helper.

let printerName = "BlueTooth Printer"
let maxJobBytes = 8 * 1024 * 1024

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func normalizeAddress(_ raw: String) -> String {
    raw.uppercased().replacingOccurrences(of: "-", with: ":")
}

func deviceName(_ device: IOBluetoothDevice) -> String {
    if let name = device.name, !name.isEmpty {
        return name
    }
    return device.nameOrAddress ?? ""
}

func nameMatches(_ name: String) -> Bool {
    name == printerName || name.caseInsensitiveCompare(printerName) == .orderedSame
}

func device(for address: String) -> IOBluetoothDevice? {
    let colon = normalizeAddress(address)
    let dash = colon.replacingOccurrences(of: ":", with: "-")
    if let found = IOBluetoothDevice(addressString: dash) {
        return found
    }
    return IOBluetoothDevice(addressString: colon)
}

func cachedAddress() -> String? {
    var lists: [Any] = []
    if let paired = IOBluetoothDevice.pairedDevices() {
        lists.append(contentsOf: paired)
    }
    if let recent = IOBluetoothDevice.recentDevices(32) {
        lists.append(contentsOf: recent)
    }
    if let favorites = IOBluetoothDevice.favoriteDevices() {
        lists.append(contentsOf: favorites)
    }
    for item in lists {
        guard let device = item as? IOBluetoothDevice else {
            continue
        }
        if nameMatches(deviceName(device)), let address = device.addressString {
            return normalizeAddress(address)
        }
    }
    return nil
}

final class Finder: NSObject, IOBluetoothDeviceInquiryDelegate {
    var match: String?

    func consider(_ device: IOBluetoothDevice, inquiry: IOBluetoothDeviceInquiry) {
        let name = deviceName(device)
        let address = device.addressString ?? ""
        fputs("found \(name) \(address)\n", stderr)
        guard match == nil, nameMatches(name), !address.isEmpty else {
            return
        }
        match = normalizeAddress(address)
        print(match ?? "")
        fflush(stdout)
        // inquiry.stop() from this callback crashes. Leave the scan running
        // and return to main as soon as the printer name is known.
        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        consider(device, inquiry: sender)
    }

    func deviceInquiryDeviceNameUpdated(
        _ sender: IOBluetoothDeviceInquiry,
        device: IOBluetoothDevice,
        devicesRemaining: UInt32
    ) {
        consider(device, inquiry: sender)
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        if error != kIOReturnSuccess && match == nil {
            fputs("inquiry finished with status \(error)\n", stderr)
        }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

func discover() {
    if let cached = cachedAddress() {
        print(cached)
        return
    }
    let finder = Finder()
    guard let inquiry = IOBluetoothDeviceInquiry(delegate: finder) else {
        fail("inquiry allocation failed")
    }
    inquiry.updateNewDeviceNames = true
    inquiry.inquiryLength = 20
    let started = inquiry.start()
    if started != kIOReturnSuccess {
        fail("inquiry start failed: \(started)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
    CFRunLoopRun()
    inquiry.delegate = nil
    guard finder.match != nil else {
        fail("printer not found")
    }
}

final class RadioDelegate: NSObject {
    var status: IOReturn = kIOReturnSuccess

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        self.status = status
        fputs("connectionComplete \(status)\n", stderr)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        self.status = status
        fputs("sdpQueryComplete \(status)\n", stderr)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

func pump(timeout: TimeInterval) {
    let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
        fputs("radio timeout\n", stderr)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
    CFRunLoopRun()
    timer.invalidate()
}

func serialChannel(on device: IOBluetoothDevice, fallback: UInt8) -> UInt8 {
    var channels: [UInt8] = []
    for item in device.services ?? [] {
        guard let record = item as? IOBluetoothSDPServiceRecord else {
            continue
        }
        var found: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&found) == kIOReturnSuccess else {
            continue
        }
        fputs("service \(record.getServiceName() ?? "") channel \(found)\n", stderr)
        channels.append(found)
    }
    if let uuid = IOBluetoothSDPUUID.uuid16(BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassSerialPort.rawValue)),
       let record = device.getServiceRecord(for: uuid) {
        var found: BluetoothRFCOMMChannelID = 0
        if record.getRFCOMMChannelID(&found) == kIOReturnSuccess {
            fputs("serial port channel \(found)\n", stderr)
            return found
        }
    }
    if channels.contains(fallback) {
        return fallback
    }
    if let first = channels.first {
        return first
    }
    fputs("serial port record missing, using channel \(fallback)\n", stderr)
    return fallback
}

func prepare(_ device: IOBluetoothDevice, fallback: UInt8) -> UInt8 {
    let radio = RadioDelegate()
    if !device.isConnected() {
        let pageTimeout = BluetoothHCIPageTimeout(16_000)
        let started = device.openConnection(
            radio,
            withPageTimeout: pageTimeout,
            authenticationRequired: false
        )
        fputs("openConnection \(started)\n", stderr)
        if started == kIOReturnSuccess && !device.isConnected() {
            pump(timeout: 12)
        }
    }
    fputs("connected=\(device.isConnected())\n", stderr)
    let sdpStarted = device.performSDPQuery(radio)
    fputs("sdp start \(sdpStarted)\n", stderr)
    if sdpStarted == kIOReturnSuccess {
        pump(timeout: 12)
    }
    return serialChannel(on: device, fallback: fallback)
}

// The RFCOMM channel does not retain its delegate.
private var retainedChannelDelegates: [ChannelDelegate] = []

final class ChannelDelegate: NSObject {
    var channel: IOBluetoothRFCOMMChannel?
    var status: IOReturn = kIOReturnError

    @objc func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel, status: IOReturn) {
        self.channel = rfcommChannel
        self.status = status
        fputs("rfcomm open complete \(status)\n", stderr)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) {
        fputs("rfcomm closed\n", stderr)
    }

    @objc func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel,
        data dataPointer: UnsafeMutableRawPointer,
        length dataLength: Int
    ) {
    }
}

func openChannel(address: String, channelID: UInt8) -> IOBluetoothRFCOMMChannel {
    guard let device = device(for: address) else {
        fail("device not found: \(address)")
    }
    var lastStatus: IOReturn = kIOReturnError
    for attempt in 1...4 {
        let resolved = prepare(device, fallback: channelID)
        let delegate = ChannelDelegate()
        var channel: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&channel, withChannelID: resolved, delegate: delegate)
        fputs("RFCOMM async \(status) channel \(resolved)\n", stderr)
        if status == kIOReturnSuccess {
            pump(timeout: 15)
            if delegate.status == kIOReturnSuccess, let opened = delegate.channel ?? channel, opened.isOpen() {
                fputs("RFCOMM channel \(resolved) open\n", stderr)
                retainedChannelDelegates.append(delegate)
                return opened
            }
            lastStatus = delegate.status
        } else {
            lastStatus = status
        }
        fputs("RFCOMM attempt \(attempt) failed: \(lastStatus)\n", stderr)
        _ = channel?.close()
        _ = device.closeConnection()
        Thread.sleep(forTimeInterval: 1)
    }
    fail("RFCOMM failed: \(lastStatus)")
}

func send(address: String, channelID: UInt8) {
    let channel = openChannel(address: address, channelID: channelID)
    // The bridge waits for this line before it reads the CUPS socket.
    fputs("READY\n", stderr)
    fflush(stderr)
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    if payload.count > maxJobBytes {
        _ = channel.close()
        fail("job exceeds \(maxJobBytes) bytes")
    }
    let mtu = max(1, Int(channel.getMTU()))
    let bytes = [UInt8](payload)
    var offset = 0
    while offset < bytes.count {
        let count = min(mtu, bytes.count - offset)
        let status: IOReturn = bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return kIOReturnError
            }
            return channel.writeSync(
                UnsafeMutableRawPointer(mutating: base.advanced(by: offset)),
                length: UInt16(count)
            )
        }
        if status != kIOReturnSuccess {
            _ = channel.close()
            fail("write failed: \(status)")
        }
        offset += count
    }
    Thread.sleep(forTimeInterval: 0.3)
    _ = channel.close()
}

func channelArgument(_ raw: String) -> UInt8 {
    guard let value = UInt8(raw), value >= 1, value <= 30 else {
        fail("invalid RFCOMM channel")
    }
    return value
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: coibeu-rfcomm discover|send MAC CHANNEL")
}

switch arguments[1] {
case "discover":
    discover()
case "send":
    guard arguments.count == 4 else {
        fail("usage: coibeu-rfcomm send MAC CHANNEL")
    }
    send(address: normalizeAddress(arguments[2]), channelID: channelArgument(arguments[3]))
default:
    fail("usage: coibeu-rfcomm discover|send MAC CHANNEL")
}
