import AppKit
import Foundation
import IOBluetooth

enum SoundMode: UInt8, CaseIterable {
  case original = 0, bass = 1, vocals = 2
  var title: String {
    switch self {
    case .original: return "原声"
    case .bass: return "脉冲低音"
    case .vocals: return "悠扬人声"
    }
  }
}

struct OppoFrame {
  let command: UInt16
  let sequence: UInt8
  let payload: [UInt8]

  // Captured RFCOMM stream: AA, varint frame length, reserved(2),
  // command LE16, sequence, payload length LE16, payload. No extra CRC.
  var bytes: [UInt8] {
    let size = payload.count + 7
    var length = size
    var result: [UInt8] = [0xaa]
    repeat {
      var byte = UInt8(length & 0x7f)
      length >>= 7
      if length > 0 { byte |= 0x80 }
      result.append(byte)
    } while length > 0
    result += [0, 0, UInt8(command & 255), UInt8(command >> 8), sequence,
               UInt8(payload.count & 255), UInt8(payload.count >> 8)]
    return result + payload
  }
}

struct OppoDecoder {
  private var buffer: [UInt8] = []
  mutating func feed(_ bytes: [UInt8]) -> [OppoFrame] {
    buffer += bytes
    var frames: [OppoFrame] = []
    while !buffer.isEmpty {
      guard let start = buffer.firstIndex(of: 0xaa) else { buffer.removeAll(); break }
      if start > 0 { buffer.removeFirst(start) }
      var pos = 1
      var length = 0
      var shift = 0
      var complete = false
      while pos < buffer.count && pos <= 3 {
        let byte = buffer[pos]
        length |= Int(byte & 127) << shift
        pos += 1
        shift += 7
        if byte & 128 == 0 { complete = true; break }
      }
      if !complete {
        if pos > 3 { buffer.removeFirst(); continue }
        break
      }
      guard (7...4096).contains(length) else { buffer.removeFirst(); continue }
      let end = pos + length
      guard buffer.count >= end else { break }
      let payloadLength = Int(buffer[pos + 5]) | Int(buffer[pos + 6]) << 8
      guard buffer[pos] == 0, buffer[pos + 1] == 0, payloadLength + 7 == length else {
        buffer.removeFirst(); continue
      }
      frames.append(OppoFrame(command: UInt16(buffer[pos + 2]) | UInt16(buffer[pos + 3]) << 8,
                              sequence: buffer[pos + 4], payload: Array(buffer[(pos + 7)..<end])))
      buffer.removeFirst(end)
    }
    return frames
  }
}

final class Air2Link: NSObject, IOBluetoothRFCOMMChannelDelegate {
  var status: (String) -> Void = { _ in }
  var log: (String) -> Void = { _ in }
  var changed: (Bool, Bool) -> Void = { _, _ in }
  private var device: IOBluetoothDevice?
  private var channel: IOBluetoothRFCOMMChannel?
  private var decoder = OppoDecoder()
  private var sequence: UInt8 = 0x22
  private var pending: (command: UInt16, sequence: UInt8, receive: (OppoFrame) -> Void)?
  private var timeout: Timer?
  private(set) var ready = false
  private(set) var busy = false
  private(set) var mode: SoundMode?
  private var connecting = false

  static func devices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
      let name = ($0.name ?? "").lowercased().replacingOccurrences(of: " ", with: "")
      return name.contains("encoair2")
    }
  }

  func connect(_ target: IOBluetoothDevice) {
    disconnect()
    device = target
    connecting = true
    update(busy: true)
    status("正在发现耳机控制服务…")
    armTimeout("发现服务超时，请确认耳机连接 Mac，并断开安卓欢律。", seconds: 15)
    let result = target.performSDPQuery(self)
    if result != kIOReturnSuccess { fail("SDP 启动失败：\(result)") }
  }

  @objc func sdpQueryComplete(_ target: IOBluetoothDevice, status result: IOReturn) {
    guard connecting, device === target else { return }
    guard result == kIOReturnSuccess else { fail("发现服务失败：\(result)"); return }
    let uuidBytes: [UInt8] = [0, 0, 7, 0x9a, 0xd1, 2, 0x11, 0xe1, 0x9b, 0x23, 0, 2, 0x5b, 0, 0xa5, 0xa5]
    let uuid = IOBluetoothSDPUUID(data: Data(uuidBytes))
    guard let service = target.getServiceRecord(for: uuid) else {
      fail("未找到 Air2 的 079A 控制服务；不会尝试其他蓝牙通道。")
      return
    }
    var channelID: BluetoothRFCOMMChannelID = 0
    guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
      fail("服务没有 RFCOMM 通道。")
      return
    }
    log("已发现控制服务，RFCOMM 通道 \(channelID)（安卓抓包为 15）")
    status("正在连接控制通道…")
    armTimeout("连接控制通道超时。", seconds: 15)
    let openResult = target.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
    if openResult != kIOReturnSuccess { fail("打开控制通道失败：\(openResult)") }
  }

  func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
    guard connecting else { return }
    guard error == kIOReturnSuccess else { fail("控制通道连接失败：\(error)"); return }
    channel = rfcommChannel
    connecting = false
    status("已连接，正在握手…")
    request(0x0100, response: 0x8100) { [weak self] frame in
      guard let self = self else { return }
      guard frame.payload.first == 0 else { self.fail("耳机拒绝握手。"); return }
      self.ready = true
      self.query()
    }
  }

  func query() {
    guard ready else { return }
    update(busy: true)
    status("正在读取当前音效…")
    readMode { [weak self] actual in
      guard let self = self else { return }
      self.mode = actual
      self.status("当前音效：\(actual.title)（已从耳机读回）")
      self.update(busy: false)
    }
  }

  func setMode(_ desired: SoundMode) {
    guard ready, !busy else { return }
    update(busy: true)
    status("正在切换为\(desired.title)…")
    request(0x0406, payload: [desired.rawValue], response: 0x8406) { [weak self] frame in
      guard let self = self else { return }
      guard frame.payload == [0] else { self.fail("耳机拒绝切换音效。"); return }
      self.readMode { [weak self] actual in
        guard let self = self else { return }
        self.mode = actual
        guard actual == desired else {
          self.fail("读回音效为\(actual.title)，与请求不一致；未确认切换成功。")
          return
        }
        self.status("已切换：\(actual.title)（回复与读回均通过）")
        self.update(busy: false)
      }
    }
  }

  private func readMode(_ receive: @escaping (SoundMode) -> Void) {
    request(0x010f, response: 0x810f) { [weak self] frame in
      guard frame.payload.count == 2, frame.payload[0] == 0,
            let value = SoundMode(rawValue: frame.payload[1]) else {
        self?.fail("当前音效回复格式不符合这台耳机的抓包记录。")
        return
      }
      receive(value)
    }
  }

  private func request(_ command: UInt16, payload: [UInt8] = [], response: UInt16,
                       receive: @escaping (OppoFrame) -> Void) {
    guard let channel = channel else { fail("控制通道未连接。"); return }
    sequence &+= 1
    var bytes = OppoFrame(command: command, sequence: sequence, payload: payload).bytes
    pending = (response, sequence, receive)
    log("TX " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
    armTimeout(String(format: "等待 0x%04X 回复超时；未确认操作成功。", response), seconds: 6)
    let size = UInt16(bytes.count)
    let result = bytes.withUnsafeMutableBytes { raw in channel.writeSync(raw.baseAddress, length: size) }
    if result != kIOReturnSuccess { fail("发送失败：\(result)") }
  }

  func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!,
                         length dataLength: Int) {
    guard let pointer = dataPointer, dataLength > 0 else { return }
    for frame in decoder.feed(Array(UnsafeRawBufferPointer(start: pointer, count: dataLength))) {
      // Unsolicited diagnostics may contain unrelated device information; only log replies to our commands.
      guard let waiting = pending, frame.command == waiting.command, frame.sequence == waiting.sequence else { continue }
      log("RX " + frame.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
      pending = nil
      timeout?.invalidate()
      waiting.receive(frame)
    }
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    if ready || busy || connecting { fail("耳机控制通道已断开，请重新连接。") }
  }

  private func armTimeout(_ message: String, seconds: TimeInterval) {
    timeout?.invalidate()
    timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.fail(message) }
  }

  private func update(busy value: Bool) {
    busy = value
    changed(ready, busy)
  }

  private func fail(_ message: String) {
    log(message)
    disconnect()
    status(message)
  }

  func disconnect() {
    timeout?.invalidate()
    pending = nil
    connecting = false
    ready = false
    mode = nil
    let previous = channel
    channel = nil
    update(busy: false)
    _ = previous?.setDelegate(nil)
    _ = previous?.close()
    decoder = OppoDecoder()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let link = Air2Link()
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
  let statusLabel = NSTextField(wrappingLabelWithString: "请先将 Air2 新声版连接到 Mac。")
  let devicePicker = NSPopUpButton()
  let connectButton = NSButton(title: "连接并读取", target: nil, action: nil)
  let refreshButton = NSButton(title: "刷新设备", target: nil, action: nil)
  let queryButton = NSButton(title: "读取当前音效", target: nil, action: nil)
  let logView = NSTextView()
  var devices: [IOBluetoothDevice] = []
  var modeButtons: [NSButton] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    window.title = "o+耳机控制"
    window.center()
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 14
    root.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(root)
    if let content = window.contentView {
      NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                                   root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
                                   root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                                   root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)])
    }
    let title = NSTextField(labelWithString: "切换耳机内置音效")
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    root.addArrangedSubview(title)
    let row = NSStackView(views: [devicePicker, refreshButton, connectButton])
    row.spacing = 8
    root.addArrangedSubview(row)
    devicePicker.widthAnchor.constraint(equalToConstant: 285).isActive = true
    statusLabel.font = .systemFont(ofSize: 14)
    root.addArrangedSubview(statusLabel)
    statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    modeButtons = SoundMode.allCases.map { mode in
      let button = NSButton(title: mode.title, target: self, action: #selector(selectMode(_:)))
      button.tag = Int(mode.rawValue)
      button.bezelStyle = .rounded
      button.isEnabled = false
      return button
    }
    let modes = NSStackView(views: modeButtons + [queryButton])
    modes.spacing = 10
    root.addArrangedSubview(modes)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    logView.isEditable = false
    logView.isSelectable = true
    logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    logView.autoresizingMask = [.width]
    logView.isVerticallyResizable = true
    logView.isHorizontallyResizable = false
    logView.textContainer?.widthTracksTextView = true
    scroll.documentView = logView
    root.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    connectButton.target = self; connectButton.action = #selector(connect)
    refreshButton.target = self; refreshButton.action = #selector(refreshDevices)
    queryButton.target = self; queryButton.action = #selector(query)
    queryButton.isEnabled = false
    link.status = { [weak self] message in self?.statusLabel.stringValue = message }
    link.log = { [weak self] message in self?.appendLog(message) }
    link.changed = { [weak self] ready, busy in
      guard let self = self else { return }
      self.connectButton.isEnabled = !busy && !self.devices.isEmpty
      self.refreshButton.isEnabled = !busy
      self.devicePicker.isEnabled = !busy
      self.queryButton.isEnabled = ready && !busy
      self.modeButtons.forEach { $0.isEnabled = ready && !busy }
    }
    let menu = NSMenu()
    let item = NSMenuItem(); menu.addItem(item)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "退出 o+耳机控制", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = appMenu
    NSApp.mainMenu = menu
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    refreshDevices()
    if devices.count == 1 { connect() }
  }

  func appendLog(_ message: String) {
    logView.textStorage?.append(NSAttributedString(string: message + "\n"))
    logView.scrollToEndOfDocument(nil)
  }
  @objc func refreshDevices() {
    link.disconnect()
    devices = Air2Link.devices()
    devicePicker.removeAllItems()
    devicePicker.addItems(withTitles: devices.map { $0.name ?? "Air2" })
    connectButton.isEnabled = !devices.isEmpty
    statusLabel.stringValue = devices.isEmpty ? "未找到已配对的 Air2。请检查系统蓝牙权限，然后点刷新设备。" : "请选择耳机并连接。"
    appendLog("匹配到 \(devices.count) 台已配对的 Air2。")
  }
  @objc func connect() {
    guard devices.indices.contains(devicePicker.indexOfSelectedItem) else { return }
    link.connect(devices[devicePicker.indexOfSelectedItem])
  }
  @objc func query() { link.query() }
  @objc func selectMode(_ sender: NSButton) {
    guard let mode = SoundMode(rawValue: UInt8(sender.tag)) else { return }
    link.setMode(mode)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { link.disconnect() }
}

if CommandLine.arguments.contains("--self-test") {
  let expected: [UInt8] = [0xaa, 0x08, 0, 0, 0x06, 0x04, 0x4e, 1, 0, 1]
  precondition(OppoFrame(command: 0x0406, sequence: 0x4e, payload: [1]).bytes == expected)
  var decoder = OppoDecoder()
  let captured = [UInt8]([0xaa, 9, 0, 0, 0x0f, 0x81, 0x4f, 2, 0, 0, 1])
  precondition(decoder.feed(Array(captured.prefix(4))).isEmpty)
  let frames = decoder.feed(Array(captured.dropFirst(4)) + captured)
  precondition(frames.count == 2 && frames.allSatisfy { $0.command == 0x810f && $0.sequence == 0x4f && $0.payload == [0, 1] })
  let large = OppoFrame(command: 0x0204, sequence: 0, payload: [UInt8](repeating: 0, count: 222))
  precondition(decoder.feed(large.bytes).first?.payload.count == 222)
  print("PASS: 抓包指令编码、分片／合并读取与长消息解码；未访问蓝牙。")
} else {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
}
