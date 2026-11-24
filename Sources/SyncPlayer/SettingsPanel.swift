import AppKit

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Floating panel with every setting. Opens with S (or the ⚙ key ","). Same on master and follower;
/// the transport buttons work only on the master.
final class SettingsPanel: NSPanel {
    private unowned let app: AppController
    private var refreshers: [() -> Void] = []
    private let stack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let roleSeg = NSSegmentedControl(labels: ["マスター", "フォロワー"], trackingMode: .selectOne, target: nil, action: nil)
    private let fileLabel = NSTextField(labelWithString: "")
    private let presetPopup = NSPopUpButton()
    private let presetName = NSTextField(string: "")
    private let screenPopup = NSPopUpButton()
    private let meshPopup = NSPopUpButton()

    init(app: AppController) {
        self.app = app
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "SyncPlayer 設定"
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        build()
    }

    // MARK: building blocks

    private func header(_ t: String) {
        let l = NSTextField(labelWithString: t)
        l.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(l)
    }

    private func row(_ views: [NSView]) {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 6
        stack.addArrangedSubview(r)
    }

    private func button(_ t: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: t, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func check(_ t: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let b = ClosureButton(checkboxWithTitle: t) { _ in }
        b.onClick = { [weak b] in set(b?.state == .on) }
        refreshers.append { [weak b] in b?.state = get() ? .on : .off }
        return b
    }

    private func slider(_ t: String, _ lo: Double, _ hi: Double, fmt: String = "%.3f",
                        _ key: WritableKeyPath<DisplaySettings, Double>) {
        let label = NSTextField(labelWithString: t)
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let s = ClosureSlider(value: 0, minValue: lo, maxValue: hi) { _ in }
        s.isContinuous = true
        s.controlSize = .small
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        s.onChange = { [weak self, weak s, weak value] in
            guard let self, let s else { return }
            var st = self.app.settings
            st[keyPath: key] = s.doubleValue
            self.app.updateSettings(st)
            value?.stringValue = String(format: fmt, s.doubleValue)
        }
        refreshers.append { [weak self, weak s, weak value] in
            guard let self, let s else { return }
            let v = self.app.settings[keyPath: key]
            s.doubleValue = v
            value?.stringValue = String(format: fmt, v)
        }
        row([label, s, value])
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // Role
        header("役（M で切り替え）")
        roleSeg.target = self
        roleSeg.action = #selector(roleChanged)
        row([roleSeg])
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(status)

        // Movie
        header("映像")
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        row([button("開く…") { [unowned self] in self.app.openFile() }, fileLabel])
        row([check("音を出す（A）", get: { [unowned self] in self.app.audioOn },
                   set: { [unowned self] in self.app.setAudio($0) })])

        // Transport
        header("再生（マスターだけ）")
        row([button("頭へ（R）") { [unowned self] in self.app.master?.jump(to: 0) },
             button("−5 秒（←）") { [unowned self] in self.app.master?.jump(by: -5) },
             button("再生／停止（space）") { [unowned self] in self.app.master?.togglePlay() },
             button("+5 秒（→）") { [unowned self] in self.app.master?.jump(by: 5) }])

        // Content transform
        header("位置・大きさ・回転（+ − [ ] 、0 で戻す）")
        slider("横", -1, 1, \.posX)
        slider("縦", -1, 1, \.posY)
        slider("大きさ", 0.1, 4, \.scale)
        slider("回転 °", -180, 180, fmt: "%.1f", \.rotation)
        row([button("位置・大きさ・回転を戻す") { [unowned self] in
            var s = self.app.settings; s.resetTransform(); self.app.updateSettings(s) }])

        header("切り取り（元の映像の端を隠す）")
        slider("左", 0, 0.5, \.cropL)
        slider("右", 0, 0.5, \.cropR)
        slider("上", 0, 0.5, \.cropT)
        slider("下", 0, 0.5, \.cropB)

        header("エッジブレンド（窓の端を暗くぼかす）")
        slider("左", 0, 0.5, \.blendL)
        slider("右", 0, 0.5, \.blendR)
        slider("上", 0, 0.5, \.blendT)
        slider("下", 0, 0.5, \.blendB)
        slider("ガンマ", 1, 3, fmt: "%.2f", \.blendGamma)

        header("変形（窓の上で点をドラッグ、Tab で次の点、矢印で 1 px、shift で 10 px）")
        for n in 2...8 { meshPopup.addItem(withTitle: "\(n)×\(n)") }
        meshPopup.target = self
        meshPopup.action = #selector(meshSize)
        row([button("四隅（E）") { [unowned self] in self.app.toggleEdit(.corners) },
             button("曲面メッシュ（W）") { [unowned self] in self.app.toggleEdit(.mesh) },
             meshPopup])
        row([button("四隅を戻す") { [unowned self] in
                var s = self.app.settings; s.resetCorners(); self.app.updateSettings(s) },
             button("メッシュを戻す") { [unowned self] in
                var s = self.app.settings; s.resetMesh(); self.app.updateSettings(s) },
             check("格子（G）", get: { [unowned self] in self.app.settings.showGrid },
                   set: { [unowned self] v in var s = self.app.settings; s.showGrid = v; self.app.updateSettings(s) })])

        header("画面")
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged)
        row([screenPopup,
             check("全画面（F）", get: { [unowned self] in self.app.settings.fullscreen },
                   set: { [unowned self] v in self.app.setFullscreen(v) })])

        header("プリセット（1〜9 で呼び出し、⌘1〜⌘9 で保存）")
        presetName.placeholderString = "名前"
        presetName.widthAnchor.constraint(equalToConstant: 160).isActive = true
        row([presetPopup,
             button("読み込む") { [unowned self] in
                if let n = self.presetPopup.titleOfSelectedItem { self.app.loadPreset(n) } },
             button("消す") { [unowned self] in
                if let n = self.presetPopup.titleOfSelectedItem { self.app.deletePreset(n) } }])
        row([presetName, button("この名前で保存") { [unowned self] in
            let n = self.presetName.stringValue.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { self.app.savePreset(n) } }])

        header("キー")
        let keys = NSTextField(wrappingLabelWithString: AppController.keyHelp)
        keys.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        keys.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(keys)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor)])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        contentView = scroll
        refresh()
    }

    @objc private func roleChanged() { app.setRole(master: roleSeg.selectedSegment == 0) }
    @objc private func meshSize() {
        var s = app.settings
        s.setMeshSize(meshPopup.indexOfSelectedItem + 2)
        app.updateSettings(s)
    }
    @objc private func screenChanged() { app.moveToScreen(screenPopup.indexOfSelectedItem) }

    /// Bring every control in line with the current state.
    func refresh() {
        refreshers.forEach { $0() }
        roleSeg.selectedSegment = app.master != nil ? 0 : 1
        fileLabel.stringValue = app.node.url.lastPathComponent
        meshPopup.selectItem(at: max(0, min(6, app.settings.meshCols - 2)))
        let names = PresetStore.list()
        let sel = presetPopup.titleOfSelectedItem
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: names)
        if let sel, names.contains(sel) { presetPopup.selectItem(withTitle: sel) }
        screenPopup.removeAllItems()
        for (i, s) in NSScreen.screens.enumerated() {
            screenPopup.addItem(withTitle: "\(i + 1): \(s.localizedName) \(Int(s.frame.width))×\(Int(s.frame.height))")
        }
        screenPopup.selectItem(at: min(app.settings.screen, NSScreen.screens.count - 1))
        refreshStatus()
    }

    func refreshStatus() { status.stringValue = app.statusText() }
}

/// NSButton with a closure.
final class ClosureButton: NSButton {
    var onClick: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        onClick = action
        target = self
        self.action = #selector(fire)
    }
    convenience init(checkboxWithTitle t: String, _ unused: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        setButtonType(.switch)
        title = t
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { onClick?() }
}

/// NSSlider with a closure.
final class ClosureSlider: NSSlider {
    var onChange: (() -> Void)?
    convenience init(value: Double, minValue: Double, maxValue: Double, _ unused: @escaping (Double) -> Void) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        doubleValue = value
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { onChange?() }
}
