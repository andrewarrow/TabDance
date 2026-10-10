import AppKit

@MainActor
final class ActionButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String = "", symbol: String? = nil, label: String) {
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) }
        toolTip = label
        setAccessibilityLabel(label)
        bezelStyle = .recessed
        isBordered = false
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func press() { onPress?() }
}

@MainActor
final class WorkspaceCell: NSTableCellView {
    let nameLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [nameLabel, countLabel, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            countLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor)
        ])
        textField = nameLabel
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, count: Int, active: Bool, busy: Bool) {
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
        countLabel.stringValue = "\(count) \(count == 1 ? "tab" : "tabs")"
        toolTip = name
        setAccessibilityLabel("\(name), \(countLabel.stringValue)\(busy ? ", Codex working" : "")")
        if busy {
            spinner.isHidden = false
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spinner.stopAnimation(nil)
                spinner.isDisplayedWhenStopped = true
            } else {
                spinner.isDisplayedWhenStopped = false
                spinner.startAnimation(nil)
            }
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }
}

@MainActor
final class TerminalTabView: NSView {
    let selectButton: ActionButton
    let closeButton: ActionButton

    init(name: String, detail: String, active: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        selectButton = ActionButton(title: name, label: detail)
        closeButton = ActionButton(symbol: "xmark", label: "Close \(name)")
        super.init(frame: NSRect(x: 0, y: 0, width: 152, height: 32))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = (active ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18) : .clear).cgColor
        selectButton.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        selectButton.alignment = .left
        selectButton.lineBreakMode = .byTruncatingTail
        selectButton.onPress = onSelect
        closeButton.onPress = onClose
        for button in [selectButton, closeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 152),
            heightAnchor.constraint(equalToConstant: 32),
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class WindowContentView: NSView {
    var onResize: (() -> Void)?
    override func layout() {
        onResize?()
        super.layout()
    }
}
