// 面板里的视图。全是纯函数：数据进、NSView 出，不持有状态——
// 所以 `--preview` 能离屏渲染同一套视图，改 UI 不用重装 app。

import AppKit

enum Theme {
    static let width: CGFloat = 292
    static let inset: CGFloat = 16
    static var content: CGFloat { width - inset * 2 }
    static let corner: CGFloat = 16

    static let primary = NSColor(white: 1, alpha: 0.92)
    static let secondary = NSColor(white: 1, alpha: 0.80)
    static let tertiary = NSColor(white: 1, alpha: 0.64)  // 玻璃底透，灰字低于 0.6 就糊
    static let track = NSColor(white: 1, alpha: 0.08)
    static let rule = NSColor(white: 1, alpha: 0.07)

    static let green = NSColor(srgbRed: 0.20, green: 0.84, blue: 0.42, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.10, alpha: 1)
    static let red = NSColor(srgbRed: 1.00, green: 0.33, blue: 0.29, alpha: 1)
    static let errorText = NSColor(srgbRed: 1.00, green: 0.64, blue: 0.60, alpha: 1)

    /// <70% 绿、<90% 黄、≥90% 红。
    static func level(_ percent: Double) -> NSColor {
        percent >= 90 ? red : percent >= 70 ? yellow : green
    }

    static func brand(_ provider: String) -> NSColor {
        switch provider {
        case "Claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        default: NSColor(white: 0.88, alpha: 1)
        }
    }

    /// 数字一律等宽，倒计时每分钟变一次时不抖。
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, rounded: Bool = false) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

// MARK: - 积木

func label(_ string: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: string)
    field.font = font
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

/// 竖排，子视图撑满宽度。
func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    for view in views {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
}

/// 横排，左右两组分别贴边。左组最后一个视图吸收多余宽度（标签背景透明，看不出来），
/// 空间不够时也是它先截断。不用空白 NSView 撑：它没有基线，会把 firstBaseline 对齐搞乱。
func split(_ leading: [NSView], _ trailing: [NSView] = [], spacing: CGFloat = 6,
           alignment: NSLayoutConstraint.Attribute = .firstBaseline) -> NSStackView {
    let views = (leading.isEmpty ? [NSView()] : leading) + trailing
    let filler = leading.isEmpty ? views[0] : leading[leading.count - 1]
    for view in views {
        let flexible = view === filler
        view.setContentHuggingPriority(flexible ? .init(1) : .required, for: .horizontal)
        view.setContentCompressionResistancePriority(flexible ? .defaultLow : .required, for: .horizontal)
    }
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = alignment
    stack.distribution = .fill
    stack.spacing = spacing
    return stack
}

func hairline() -> NSView {
    let line = NSBox()
    line.boxType = .custom
    line.borderWidth = 0
    line.fillColor = Theme.rule
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

final class Dot: NSView {
    let color: NSColor
    init(_ color: NSColor, size: CGFloat = 7) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// 6pt 胶囊条。`fraction` 为 nil 表示没有数：只画一条更淡的轨道。
final class Bar: NSView {
    var fraction: Double?
    var color = Theme.green
    var dimmed = false

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        (fraction == nil ? Theme.track.withAlphaComponent(0.04) : Theme.track).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard let fraction, fraction > 0 else { return }
        let width = max(bounds.height, CGFloat(min(fraction, 1)) * bounds.width)
        let alpha: CGFloat = dimmed ? 0.45 : 1
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                                xRadius: radius, yRadius: radius)
        NSGradient(starting: color.withAlphaComponent(0.62 * alpha), ending: color.withAlphaComponent(alpha))?
            .draw(in: fill, angle: 0)
    }
}

// MARK: - 一档

/// 「43」大号圆体 +「%」小号；≥70% 时数字跟条同色。两个普通标签按基线排：
/// 混字号的 attributed 标签在 NSStackView 里不认 hugging，会被拉宽。
func percentLabels(_ value: Double?) -> [NSView] {
    guard let value else { return [label("—", Theme.font(14, .medium, rounded: true), Theme.tertiary)] }
    let color = value >= 70 ? Theme.level(value) : Theme.primary
    return [
        label(formatNumber(value), Theme.font(15, .semibold, rounded: true), color),
        label("%", Theme.font(10, .semibold, rounded: true), color.withAlphaComponent(0.6)),
    ]
}

func tooltip(_ reading: Reading) -> String {
    var lines: [String] = []
    if !reading.subtitle.isEmpty { lines.append(reading.subtitle) }
    if let used = reading.usedPercent {
        lines.append("已用 \(formatPct(used)) · 剩余 \(formatPct(max(0, 100 - used)))")
    }
    if let resets = reading.resetsAt { lines.append("\(formatReset(resets)) · \(countdown(resets))") }
    if !reading.note.isEmpty { lines.append(reading.note) }
    return lines.joined(separator: "\n")
}

/// 第二行：左边倒计时，右边绝对时刻。没有重置时刻就写 caption；没有数就写原因的第一句。
private func captions(_ reading: Reading, showReason: Bool) -> (String, String?) {
    if let resets = reading.resetsAt { return (countdown(resets), formatReset(resets)) }
    if reading.usedPercent != nil { return (reading.caption ?? "重置时刻不可用", nil) }
    let reason = reading.note.split(separator: "。").first.map(String.init) ?? ""
    return (showReason && !reason.isEmpty ? reason : "不可用", nil)
}

///     7 天  Opus                     43%
///     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
///     4 天 21 小时后重置      11月25日 17:53
func readingView(_ reading: Reading, showReason: Bool, stale: Bool) -> NSView {
    var leading: [NSView] = [label(reading.title, Theme.font(11.5, .medium), Theme.secondary)]
    if let model = reading.model { leading.append(label(model, Theme.font(10.5, .medium), Theme.tertiary)) }
    let head = split(leading, percentLabels(reading.usedPercent), spacing: 5)
    if let number = head.arrangedSubviews.dropLast().last, reading.usedPercent != nil {
        head.setCustomSpacing(1, after: number)
    }

    let bar = Bar()
    bar.fraction = reading.usedPercent.map { $0 / 100 }
    bar.color = Theme.level(reading.usedPercent ?? 0)
    bar.dimmed = stale

    let (left, right) = captions(reading, showReason: showReason)
    let caption = Theme.font(10)
    let foot = split([label(left, caption, Theme.tertiary)],
                     right.map { [label($0, caption, Theme.tertiary)] } ?? [])

    let view = column([head, bar, foot], spacing: 5)
    view.setCustomSpacing(6, after: head)
    view.toolTip = tooltip(reading)
    return view
}

// MARK: - 一家

private func errorBox(_ message: String) -> NSView {
    let text = NSTextField(wrappingLabelWithString: message)
    text.font = Theme.font(10.5)
    text.textColor = Theme.errorText
    text.maximumNumberOfLines = 3
    text.cell?.truncatesLastVisibleLine = true
    text.preferredMaxLayoutWidth = Theme.content - 20
    text.translatesAutoresizingMaskIntoConstraints = false

    let box = NSBox()
    box.boxType = .custom
    box.borderWidth = 0
    box.cornerRadius = 7
    box.fillColor = Theme.red.withAlphaComponent(0.13)
    box.contentViewMargins = .zero
    box.contentView?.addSubview(text)
    if let inside = box.contentView {
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: inside.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: inside.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: inside.topAnchor, constant: 7),
            text.bottomAnchor.constraint(equalTo: inside.bottomAnchor, constant: -7),
        ])
    }
    box.toolTip = message
    return box
}

func cardView(_ card: Card) -> NSView {
    let name = label(card.name, Theme.font(12, .semibold), Theme.primary)
    var trailing: [NSView] = []
    if card.stale { trailing.append(label("沿用上次", Theme.font(10, .medium), Theme.yellow.withAlphaComponent(0.85))) }
    let header = split([Dot(Theme.brand(card.name)), name], trailing, spacing: 7, alignment: .centerY)
    header.toolTip = ([card.source] + (card.footnote.isEmpty ? [] : [card.footnote])).joined(separator: "\n")

    var views: [NSView] = [header]
    if let error = card.error, !error.isEmpty { views.append(errorBox(error)) }
    views += card.readings.map {
        readingView($0, showReason: $0.note != card.error, stale: card.stale)
    }
    let view = column(views, spacing: 13)
    view.setCustomSpacing(11, after: header)
    return view
}

/// 两家之间一条分隔线。
func cardsView(_ snapshot: Snapshot?) -> NSStackView {
    guard let snapshot else {
        return column([label("还没读过，正在取…", Theme.font(11), Theme.tertiary)], spacing: 0)
    }
    var views: [NSView] = []
    for card in snapshot.cards {
        if !views.isEmpty { views.append(hairline()) }
        views.append(cardView(card))
    }
    return column(views, spacing: 16)
}
