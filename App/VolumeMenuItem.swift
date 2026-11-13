import AppKit

/// A menu row with a slider for Claude's own speaking volume (5-100 % of the Mac's output).
///
/// Every move is saved to `~/.claude/voice-volume` at once, so the next sentence uses it; letting go of the slider
/// plays a short spoken sample at the new level.
final class VolumeMenuItemView: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Int) -> Void
    private let onRelease: (Int) -> Void

    init(percent: Int, onChange: @escaping (Int) -> Void, onRelease: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.onRelease = onRelease
        slider = NSSlider(value: Double(percent), minValue: Double(VoiceVolume.minimum),
                          maxValue: Double(VoiceVolume.maximum), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))

        let title = NSTextField(labelWithString: "Claude's volume")
        title.font = .menuFont(ofSize: 0)
        title.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        slider.controlSize = .regular

        for view in [title, valueLabel, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
        ])
        showValue(percent)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let percent = VoiceVolume.clamp(Int(sender.doubleValue.rounded()))
        showValue(percent)
        onChange(percent)
        if NSApp.currentEvent?.type == .leftMouseUp {
            onRelease(percent)
        }
    }

    private func showValue(_ percent: Int) {
        valueLabel.stringValue = "\(percent) %"
        slider.setAccessibilityValueDescription("\(percent) percent")
    }
}

/// Plays a short spoken sample at a given volume, the way `voice-say` will sound at that level: the system voice
/// rendered by `say` to a file once, then played with a gain, like `afplay -v`.
final class VolumePreview {
    private let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-sample.aiff")
    private var sound: NSSound?
    private var rendering = false
    private var pendingGain: Float?

    func play(percent: Int) {
        let gain = Float(VoiceVolume.clamp(percent)) / 100
        if FileManager.default.fileExists(atPath: sampleURL.path) {
            start(gain: gain)
            return
        }
        pendingGain = gain
        renderSample()
    }

    private func start(gain: Float) {
        sound?.stop()
        guard let next = NSSound(contentsOf: sampleURL, byReference: true) else { return }
        next.volume = gain
        next.play()
        sound = next
    }

    private func renderSample() {
        guard !rendering else { return }
        rendering = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", sampleURL.path, "Claude voice"]
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                if finished.terminationStatus == 0, let gain = self.pendingGain {
                    self.start(gain: gain)
                }
                self.pendingGain = nil
            }
        }
        do {
            try process.run()
        } catch {
            rendering = false
            pendingGain = nil
        }
    }
}
