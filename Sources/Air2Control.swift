import AppKit
import Foundation
import IOBluetooth
import QuartzCore

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

enum ConnectionRequestAction { case wait, readCurrent, openChannel }

enum ConnectionPolicy {
  static func action(sameDevice: Bool, ready: Bool, busy: Bool) -> ConnectionRequestAction {
    if busy { return .wait }
    return sameDevice && ready ? .readCurrent : .openChannel
  }

  static func selectedIndex(previous: String?, available: [String]) -> Int? {
    if let previous = previous, let index = available.firstIndex(of: previous) { return index }
    return available.isEmpty ? nil : 0
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
      HeadphoneProfile.matching(name: $0.name ?? "") != nil
    }
  }

  func representsCurrent(_ target: IOBluetoothDevice) -> Bool {
    guard let address = device?.addressString, let other = target.addressString else { return false }
    return address == other
  }

  func connect(_ target: IOBluetoothDevice) {
    switch ConnectionPolicy.action(sameDevice: representsCurrent(target), ready: ready, busy: busy) {
    case .wait: return
    case .readCurrent: query(); return
    case .openChannel: break
    }
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
    guard connecting, let callbackChannel = rfcommChannel, callbackChannel === channel else { return }
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
    guard let callbackChannel = rfcommChannel, callbackChannel === channel,
          let pointer = dataPointer, dataLength > 0 else { return }
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
    guard let callbackChannel = rfcommChannel, callbackChannel === channel else { return }
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

// The view renders only the capabilities declared by the selected device profile.
// Add a verified feature to its profile and implement its action in the controller.
enum FeatureCategory: String, CaseIterable {
  case sound, noiseControl, device, gestures
  var title: String {
    switch self {
    case .sound: return "声音"
    case .noiseControl: return "降噪与通透"
    case .device: return "设备"
    case .gestures: return "操作与手势"
    }
  }
}

enum FeatureID: String { case soundPreset }
enum DeviceAction { case setSoundMode(SoundMode) }

struct FeatureOption {
  let id: String
  let title: String
  let action: DeviceAction
}

struct HeadphoneFeature {
  let id: FeatureID
  let category: FeatureCategory
  let title: String
  let detail: String
  let options: [FeatureOption]
}

struct FeatureSection {
  let category: FeatureCategory
  let features: [HeadphoneFeature]
}

struct HeadphoneProfile {
  let id: String
  let features: [HeadphoneFeature]
  let matchesName: (String) -> Bool

  var sections: [FeatureSection] {
    FeatureCategory.allCases.compactMap { category in
      let matches = features.filter { $0.category == category }
      return matches.isEmpty ? nil : FeatureSection(category: category, features: matches)
    }
  }

  static let air2NewEdition = HeadphoneProfile(id: "enco-air2-new-edition", features: [
    HeadphoneFeature(id: .soundPreset, category: .sound, title: "内置音效",
                     detail: "Enco Live · 音效由耳机处理", options: SoundMode.allCases.map {
      FeatureOption(id: String($0.rawValue), title: $0.title, action: .setSoundMode($0))
    })
  ], matchesName: { name in
    let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
    // macOS may cache the short Bluetooth name without the edition suffix.
    // Match known aliases exactly so Air2 Pro / Air2i / Air20 stay excluded.
    let aliases: Set<String> = ["oppoencoair2", "encoair2",
                                "oppoencoair2新声版", "encoair2新声版"]
    return aliases.contains(normalized)
  })

  static let supported = [air2NewEdition]

  static func matching(name: String) -> HeadphoneProfile? {
    supported.first { $0.matchesName(name) }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

enum LogDisclosureGeometry {
  static let logHeight: CGFloat = 158
  static func contentHeight(current: CGFloat, expanding: Bool, expansionDelta: CGFloat) -> CGFloat {
    max(expanding ? 610 : 450, current + (expanding ? logHeight : -expansionDelta))
  }
  static func frame(from current: NSRect, heightChange: CGFloat) -> NSRect {
    NSRect(x: current.minX, y: current.minY - heightChange,
           width: current.width, height: current.height + heightChange)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let link = Air2Link()
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                        backing: .buffered, defer: false)
  let statusLabel = NSTextField(wrappingLabelWithString: "请选择耳机并连接。")
  let connectionLabel = NSTextField(labelWithString: "未连接")
  let devicePicker = NSPopUpButton()
  let connectButton = NSButton(title: "连接耳机", target: nil, action: nil)
  let refreshButton = NSButton(title: "刷新设备", target: nil, action: nil)
  let queryButton = NSButton(title: "刷新状态", target: nil, action: nil)
  let featuresStack = NSStackView()
  let logView = NSTextView()
  let logsContainer = NSView()
  let primaryContent = NSStackView()
  var primaryHeightConstraint: NSLayoutConstraint!
  let operationLabel = NSTextField(wrappingLabelWithString: "")
  var logsHeightConstraint: NSLayoutConstraint!
  var logAnimating = false
  var logExpansionDelta: CGFloat = LogDisclosureGeometry.logHeight
  var lastConnectionReady = false
  let logToggle = NSButton(title: "运行日志", target: nil, action: nil)
  let logCountLabel = NSTextField(labelWithString: "0 条")
  var devices: [IOBluetoothDevice] = []
  var selectedProfile: HeadphoneProfile?
  var featureButtons: [(button: NSButton, feature: FeatureID, option: FeatureOption)] = []
  var logExpanded = false
  var logCount = 0
  let isPreview = CommandLine.arguments.contains("--ui-preview")

  func applicationDidFinishLaunching(_ notification: Notification) {
    window.title = "o+耳机控制"
    window.contentMinSize = NSSize(width: 600, height: 450)
    window.center()
    let root = primaryContent
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 18
    root.detachesHiddenViews = true
    root.translatesAutoresizingMaskIntoConstraints = false
    guard let content = window.contentView else { return }
    content.wantsLayer = true
    content.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)
    ])

    let heading = NSTextField(labelWithString: "当前耳机")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let headingRow = NSStackView(views: [heading, NSView(), refreshButton])
    headingRow.alignment = .centerY
    root.addArrangedSubview(headingRow)
    headingRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

    let deviceRow = NSStackView(views: [devicePicker, connectButton])
    deviceRow.spacing = 12
    deviceRow.alignment = .centerY
    devicePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
    devicePicker.setAccessibilityLabel("当前耳机")
    connectButton.setContentHuggingPriority(.required, for: .horizontal)
    root.addArrangedSubview(deviceRow)
    deviceRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    devicePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

    connectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
    connectionLabel.textColor = .secondaryLabelColor
    let statusRow = NSStackView(views: [connectionLabel, NSView(), queryButton])
    statusRow.alignment = .centerY
    root.addArrangedSubview(statusRow)
    statusRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    root.setCustomSpacing(6, after: statusRow)
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 2
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.heightAnchor.constraint(equalToConstant: 34).isActive = true
    root.addArrangedSubview(statusLabel)
    statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

    let featureScroll = NSScrollView()
    featureScroll.hasVerticalScroller = true
    featureScroll.drawsBackground = false
    featureScroll.borderType = .noBorder
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    featureScroll.documentView = document
    featuresStack.orientation = .vertical
    featuresStack.alignment = .leading
    featuresStack.spacing = 16
    featuresStack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(featuresStack)
    NSLayoutConstraint.activate([
      document.widthAnchor.constraint(equalTo: featureScroll.contentView.widthAnchor),
      featuresStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      featuresStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
      featuresStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
      featuresStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
    ])
    root.addArrangedSubview(featureScroll)
    featureScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    featureScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    featureScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

    let divider = NSBox()
    divider.boxType = .separator
    root.addArrangedSubview(divider)
    divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    root.setCustomSpacing(8, after: divider)
    logToggle.isBordered = false
    logToggle.font = .systemFont(ofSize: 12, weight: .medium)
    logToggle.imagePosition = .imageLeading
    logToggle.target = self
    logToggle.action = #selector(toggleLogs)
    logCountLabel.font = .systemFont(ofSize: 11)
    logCountLabel.textColor = .tertiaryLabelColor
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    let versionLabel = NSTextField(labelWithString: "v\(version)")
    versionLabel.font = .systemFont(ofSize: 11)
    versionLabel.textColor = .secondaryLabelColor
    versionLabel.toolTip = "构建号：\(build)"
    versionLabel.setAccessibilityLabel("应用版本 \(version)，构建 \(build)")
    let logHeader = NSStackView(views: [logToggle, NSView(), logCountLabel, versionLabel])
    logHeader.spacing = 12
    logHeader.alignment = .centerY
    root.addArrangedSubview(logHeader)
    logHeader.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    root.setCustomSpacing(0, after: logHeader)

    logsContainer.wantsLayer = true
    logsContainer.layer?.masksToBounds = true
    let logScroll = NSScrollView()
    logScroll.hasVerticalScroller = true
    logScroll.borderType = .bezelBorder
    logView.isEditable = false
    logView.isSelectable = true
    logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    logView.textContainerInset = NSSize(width: 8, height: 8)
    logView.autoresizingMask = [.width]
    logView.isVerticallyResizable = true
    logView.isHorizontallyResizable = false
    logView.textContainer?.widthTracksTextView = true
    logScroll.documentView = logView
    logScroll.translatesAutoresizingMaskIntoConstraints = false
    logsContainer.addSubview(logScroll)
    NSLayoutConstraint.activate([
      logScroll.leadingAnchor.constraint(equalTo: logsContainer.leadingAnchor),
      logScroll.trailingAnchor.constraint(equalTo: logsContainer.trailingAnchor),
      logScroll.topAnchor.constraint(equalTo: logsContainer.topAnchor, constant: 8),
      logScroll.heightAnchor.constraint(equalToConstant: 150)
    ])
    // The upper panel and the log drawer have separate layout ownership.
    // During disclosure only the window frame animates; its extra space goes
    // into the drawer while the primary panel keeps its exact measured height.
    logsContainer.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(logsContainer)
    NSLayoutConstraint.activate([
      logsContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      logsContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      logsContainer.topAnchor.constraint(equalTo: root.bottomAnchor),
      logsContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
    ])
    primaryHeightConstraint = root.heightAnchor.constraint(equalToConstant: 0)
    logsHeightConstraint = logsContainer.heightAnchor.constraint(equalToConstant: 0)
    logsHeightConstraint.isActive = true
    logsContainer.alphaValue = 0
    logsContainer.isHidden = true
    updateLogDisclosure()

    connectButton.target = self; connectButton.action = #selector(connect)
    refreshButton.target = self; refreshButton.action = #selector(refreshDevices)
    devicePicker.target = self; devicePicker.action = #selector(selectDevice)
    queryButton.target = self; queryButton.action = #selector(query)
    link.status = { [weak self] message in
      guard let self = self else { return }
      if self.link.ready {
        self.operationLabel.stringValue = message
      } else {
        self.statusLabel.stringValue = message
      }
    }
    link.log = { [weak self] message in self?.appendLog(message) }
    link.changed = { [weak self] _, _ in self?.updateControls() }
    let menu = NSMenu()
    let item = NSMenuItem(); menu.addItem(item)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "退出 o+耳机控制", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = appMenu
    NSApp.mainMenu = menu
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    refreshDevices()
    if !isPreview && devices.count == 1 && selectedProfile != nil { connect() }
  }

  func renderFeatures() {
    featuresStack.arrangedSubviews.forEach {
      featuresStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    featureButtons.removeAll()
    guard let profile = selectedProfile, !profile.sections.isEmpty else {
      let empty = NSTextField(wrappingLabelWithString: selectedProfile == nil
        ? "选择已适配的耳机后，这里会按分类显示支持的功能。"
        : "当前型号暂无已验证的控制功能。")
      empty.textColor = .secondaryLabelColor
      empty.font = .systemFont(ofSize: 13)
      featuresStack.addArrangedSubview(empty)
      empty.widthAnchor.constraint(equalTo: featuresStack.widthAnchor).isActive = true
      return
    }
    for section in profile.sections {
      let categoryTitle = NSTextField(labelWithString: section.category.title)
      categoryTitle.font = .systemFont(ofSize: 14, weight: .semibold)
      featuresStack.addArrangedSubview(categoryTitle)
      for feature in section.features {
        let card = NSBox()
        card.boxType = .custom
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.cornerRadius = 10
        card.contentViewMargins = NSSize(width: 16, height: 14)
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        guard let cardContent = card.contentView else { continue }
        cardContent.addSubview(body)
        NSLayoutConstraint.activate([
          body.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
          body.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
          body.topAnchor.constraint(equalTo: cardContent.topAnchor),
          body.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: feature.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        body.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let detail = NSTextField(wrappingLabelWithString: feature.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        body.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let options = NSStackView()
        options.spacing = 10
        options.distribution = .fillEqually
        for option in feature.options {
          let button = NSButton(title: option.title, target: self, action: #selector(performFeature(_:)))
          button.bezelStyle = .rounded
          button.setButtonType(.pushOnPushOff)
          button.tag = featureButtons.count
          button.setAccessibilityLabel("\(feature.title)：\(option.title)")
          featureButtons.append((button, feature.id, option))
          options.addArrangedSubview(button)
        }
        body.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        featuresStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: featuresStack.widthAnchor).isActive = true
      }
    }
    operationLabel.font = .systemFont(ofSize: 11)
    operationLabel.textColor = .secondaryLabelColor
    operationLabel.maximumNumberOfLines = 2
    operationLabel.lineBreakMode = .byTruncatingTail
    featuresStack.addArrangedSubview(operationLabel)
    operationLabel.widthAnchor.constraint(equalTo: featuresStack.widthAnchor).isActive = true
    operationLabel.heightAnchor.constraint(equalToConstant: 34).isActive = true
    updateControls()
  }

  func updateControls() {
    let supported = selectedProfile != nil
    // Busy describes an in-flight operation, not a lost connection. Keep the
    // header stable; handlers coalesce repeated operations while a request runs.
    setEnabled(connectButton, !isPreview && !link.busy && !link.ready && supported && !devices.isEmpty)
    setEnabled(refreshButton, !link.busy || link.ready)
    setEnabled(devicePicker, !isPreview && (!link.busy || link.ready) && !devices.isEmpty)
    setEnabled(queryButton, link.ready && supported)
    let connectionText = isPreview ? "界面预览" : (link.ready ? "已连接" : (link.busy ? "正在连接…" : "未连接"))
    if connectionLabel.stringValue != connectionText { connectionLabel.stringValue = connectionText }
    if lastConnectionReady != link.ready {
      lastConnectionReady = link.ready
      connectionLabel.textColor = link.ready ? .systemGreen : .secondaryLabelColor
      if link.ready { statusLabel.stringValue = "耳机已连接，可调整支持的功能。" }
      else { operationLabel.stringValue = "" }
    }
    // State comes only from the device readback; clicking a choice is not success.
    var values: [FeatureID: String] = [:]
    if let mode = link.mode, link.ready { values[.soundPreset] = String(mode.rawValue) }
    for control in featureButtons {
      setEnabled(control.button, supported && link.ready)
      let state: NSControl.StateValue = values[control.feature] == control.option.id ? .on : .off
      if control.button.state != state { control.button.state = state }
    }
  }

  func appendLog(_ message: String) {
    logCount += 1
    logCountLabel.stringValue = "\(logCount) 条"
    logView.textStorage?.append(NSAttributedString(string: message + "\n"))
    if logExpanded { logView.scrollToEndOfDocument(nil) }
  }

  func setEnabled(_ control: NSControl, _ enabled: Bool) {
    if control.isEnabled != enabled { control.isEnabled = enabled }
  }

  @objc func toggleLogs() {
    guard !logAnimating else { return }
    window.contentView?.layoutSubtreeIfNeeded()
    logAnimating = true
    logExpanded.toggle()
    let size = window.contentView?.bounds.size ?? NSSize(width: 660, height: 500)
    let targetHeight = LogDisclosureGeometry.contentHeight(current: size.height,
      expanding: logExpanded, expansionDelta: logExpansionDelta)
    let heightChange = targetHeight - size.height
    if logExpanded { logExpansionDelta = heightChange }
    if !logExpanded { window.contentMinSize = NSSize(width: 600, height: 450) }
    let targetFrame = LogDisclosureGeometry.frame(from: window.frame, heightChange: heightChange)

    // Do not animate two competing height constraints. Freeze the primary
    // panel and let the drawer absorb the window's change on every frame.
    primaryHeightConstraint.constant = primaryContent.bounds.height
    logsHeightConstraint.isActive = false
    primaryHeightConstraint.isActive = true
    logsContainer.isHidden = false
    updateLogDisclosure()
    window.contentView?.layoutSubtreeIfNeeded()
    let duration: TimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      context.allowsImplicitAnimation = false
      self.logsContainer.animator().alphaValue = self.logExpanded ? 1 : 0
      self.window.animator().setFrame(targetFrame, display: true)
    }, completionHandler: { [weak self] in
      guard let self = self else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        self.primaryHeightConstraint.isActive = false
        self.logsHeightConstraint.constant = self.logExpanded ? self.logExpansionDelta : 0
        self.logsHeightConstraint.isActive = true
        self.logsContainer.isHidden = !self.logExpanded
        self.window.contentMinSize = NSSize(width: 600, height: self.logExpanded ? 610 : 450)
        self.window.contentView?.layoutSubtreeIfNeeded()
      }
      self.logAnimating = false
      if self.logExpanded { self.logView.scrollToEndOfDocument(nil) }
    })
  }

  func updateLogDisclosure() {
    logToggle.image = NSImage(systemSymbolName: logExpanded ? "chevron.down" : "chevron.right",
                             accessibilityDescription: nil)
    logToggle.setAccessibilityLabel(logExpanded ? "收起运行日志" : "展开运行日志")
  }

  @objc func refreshDevices() {
    guard !link.busy else {
      appendLog("正在等待耳机回复，保留当前连接；请稍后刷新设备列表。")
      return
    }
    let previousDevice = devices.indices.contains(devicePicker.indexOfSelectedItem)
      ? devices[devicePicker.indexOfSelectedItem] : nil
    let previousAddress = previousDevice?.addressString
    devicePicker.removeAllItems()
    if isPreview {
      devices = []
      devicePicker.addItem(withTitle: "OPPO Enco Air2（新声版）")
      selectedProfile = .air2NewEdition
      statusLabel.stringValue = "界面预览模式，未访问蓝牙设备。"
      renderFeatures()
      updateControls()
      appendLog("界面预览：日志默认折叠，音效操作未执行。")
      return
    }
    devices = Air2Link.devices()
    if link.ready, let previousDevice = previousDevice, link.representsCurrent(previousDevice),
       !devices.contains(where: { $0.addressString == previousAddress }) {
      devices.insert(previousDevice, at: 0)
      appendLog("系统配对列表暂未返回当前耳机，保留现有控制连接。")
    }
    devicePicker.addItems(withTitles: devices.map { $0.name ?? "未命名耳机" })
    let index = ConnectionPolicy.selectedIndex(previous: previousAddress,
      available: devices.map { $0.addressString ?? "" })
    if let index = index { devicePicker.selectItem(at: index) }
    else { devicePicker.addItem(withTitle: "未找到已配对的耳机") }
    if let index = index, previousAddress == devices[index].addressString, selectedProfile != nil {
      updateControls()
    } else {
      selectDevice()
    }
    let pairedCount = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).count
    appendLog("系统返回 \(pairedCount) 台已配对设备，匹配到 \(devices.count) 台已适配耳机。")
    if pairedCount == 0 && !link.ready {
      statusLabel.stringValue = "未读取到已配对设备。请确认系统蓝牙已开启，并在隐私与安全性 → 蓝牙中允许 o+耳机控制。"
    }
  }

  @objc func selectDevice() {
    if devices.indices.contains(devicePicker.indexOfSelectedItem),
       link.representsCurrent(devices[devicePicker.indexOfSelectedItem]), link.ready {
      updateControls()
      return
    }
    link.disconnect()
    if devices.indices.contains(devicePicker.indexOfSelectedItem) {
      let name = devices[devicePicker.indexOfSelectedItem].name ?? ""
      selectedProfile = HeadphoneProfile.matching(name: name)
      statusLabel.stringValue = selectedProfile == nil ? "该型号尚未适配。" : "已识别支持的型号，连接后可读取和调整。"
    } else {
      selectedProfile = nil
      statusLabel.stringValue = "请先在系统蓝牙设置中配对并连接耳机，再刷新设备。"
    }
    renderFeatures()
    updateControls()
  }

  @objc func connect() {
    guard selectedProfile != nil, devices.indices.contains(devicePicker.indexOfSelectedItem) else { return }
    link.connect(devices[devicePicker.indexOfSelectedItem])
  }
  @objc func query() { if !link.busy { link.query() } }
  @objc func performFeature(_ sender: NSButton) {
    guard featureButtons.indices.contains(sender.tag), selectedProfile != nil else { return }
    guard link.ready, !link.busy else { updateControls(); return }
    let action = featureButtons[sender.tag].option.action
    updateControls()
    switch action {
    case .setSoundMode(let mode): link.setMode(mode)
    }
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
  precondition(HeadphoneProfile.matching(name: "OPPO Enco Air2（新声版）")?.id == "enco-air2-new-edition")
  precondition(HeadphoneProfile.matching(name: "OPPO Enco Air2")?.id == "enco-air2-new-edition")
  precondition(HeadphoneProfile.matching(name: "Enco Air2")?.id == "enco-air2-new-edition")
  precondition(HeadphoneProfile.matching(name: "OPPO Enco Air2 Pro") == nil)
  precondition(HeadphoneProfile.matching(name: "OPPO Enco Air2i") == nil)
  precondition(HeadphoneProfile.matching(name: "OPPO Enco Air20") == nil)
  precondition(HeadphoneProfile.matching(name: "Unknown Headphones") == nil)
  let sections = HeadphoneProfile.air2NewEdition.sections
  precondition(sections.count == 1 && sections[0].category == .sound)
  precondition(sections[0].features.count == 1 && sections[0].features[0].options.count == 3)
  precondition(ConnectionPolicy.action(sameDevice: true, ready: true, busy: false) == .readCurrent)
  precondition(ConnectionPolicy.action(sameDevice: true, ready: true, busy: true) == .wait)
  precondition(ConnectionPolicy.action(sameDevice: false, ready: false, busy: true) == .wait)
  precondition(ConnectionPolicy.action(sameDevice: true, ready: false, busy: false) == .openChannel)
  precondition(ConnectionPolicy.selectedIndex(previous: "earbud-b", available: ["earbud-c", "earbud-b"]) == 1)
  precondition(ConnectionPolicy.selectedIndex(previous: "earbud-b", available: []) == nil)
  for height: CGFloat in [450, 500, 900] {
    let expanded = LogDisclosureGeometry.contentHeight(current: height, expanding: true, expansionDelta: 158)
    let collapsed = LogDisclosureGeometry.contentHeight(current: expanded, expanding: false, expansionDelta: expanded - height)
    precondition(collapsed == height)
    let original = NSRect(x: 100, y: 200, width: 660, height: height + 28)
    let target = LogDisclosureGeometry.frame(from: original, heightChange: expanded - height)
    precondition(target.maxY == original.maxY && target.minX == original.minX)
  }
  print("PASS: 协议、型号分类、重复连接与刷新选择策略、日志尺寸与顶部位置；未访问蓝牙。")
} else {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
}
