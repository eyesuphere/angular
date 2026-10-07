import SwiftUI
import InvoiceCore

/// A text field for a money amount that refuses to turn a typo into zero.
///
/// `TextField(value:format:.number)` bound to a Double accepts nonsense by resetting to
/// the last good value or to zero, with no feedback. On an invoice that is a silent
/// change to what the customer owes, so here the field keeps the user's text, marks it
/// invalid, and only writes through when it parses.
struct MoneyField: View {
    let title: String
    @Binding var value: Decimal
    let currency: Currency
    var width: CGFloat = 96

    @State private var text: String = ""
    @State private var isValid = true
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if !isValid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.trailing, 4)
                        .help("Not a number — the stored amount is unchanged.")
                }
            }
            .onAppear { text = Self.display(value, currency) }
            .onChange(of: value) { _, new in
                // Only overwrite the text when the model changed elsewhere, so typing
                // "1." is not reformatted out from under the cursor.
                if !focused { text = Self.display(new, currency) }
            }
            .onChange(of: text) { _, new in
                if new.trimmingCharacters(in: .whitespaces).isEmpty {
                    isValid = true
                    value = 0
                    return
                }
                if let parsed = Money(string: new, currency: currency) {
                    isValid = true
                    value = parsed.amount
                } else {
                    isValid = false
                }
            }
            .onChange(of: focused) { _, nowFocused in
                if !nowFocused {
                    // Normalise on blur, and recover the display if the text was invalid.
                    text = Self.display(value, currency)
                    isValid = true
                }
            }
    }

    private static func display(_ value: Decimal, _ currency: Currency) -> String {
        Money(value, currency).xmlValue
    }
}

/// The same treatment for a quantity or a percentage, which are not currency-scaled.
struct DecimalField: View {
    let title: String
    @Binding var value: Decimal
    var width: CGFloat = 70

    @State private var text: String = ""
    @State private var isValid = true
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if !isValid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).padding(.trailing, 4)
                }
            }
            .onAppear { text = value.rateString }
            .onChange(of: value) { _, new in if !focused { text = new.rateString } }
            .onChange(of: text) { _, new in
                if new.trimmingCharacters(in: .whitespaces).isEmpty {
                    isValid = true
                    value = 0
                } else if let parsed = Money(string: new, currency: .eur) {
                    isValid = true
                    value = parsed.amount
                } else {
                    isValid = false
                }
            }
            .onChange(of: focused) { _, nowFocused in
                if !nowFocused {
                    text = value.rateString
                    isValid = true
                }
            }
    }
}

/// Shows what would stop this invoice being accepted, before it is sent rather than
/// after a buyer's platform bounces it.
struct ValidationBanner: View {
    let issues: [ValidationIssue]

    private var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    private var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !errors.isEmpty {
                    row(icon: "exclamationmark.octagon.fill", tint: .red,
                        title: "\(errors.count) problem\(errors.count == 1 ? "" : "s") to fix "
                            + "before issuing", items: errors)
                }
                if !warnings.isEmpty {
                    row(icon: "exclamationmark.triangle.fill", tint: .orange,
                        title: "\(warnings.count) thing\(warnings.count == 1 ? "" : "s") worth "
                            + "checking", items: warnings)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(icon: String, tint: Color, title: String, items: [ValidationIssue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
            ForEach(items) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(issue.message)
                    if issue.rule != "—" {
                        Text(issue.rule)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .help("EN 16931 business rule \(issue.rule)")
                    }
                }
                .font(.callout)
                .padding(.leading, 18)
            }
        }
    }
}

/// A status pill.
struct StatusBadge: View {
    let status: InvoiceStatus
    let isOverdue: Bool

    private var tint: Color {
        if isOverdue { return .orange }
        switch status {
        case .draft: return .gray
        case .issued: return .blue
        case .paid: return .green
        case .cancelled: return .secondary
        }
    }

    private var text: String { isOverdue ? "Overdue" : status.label }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}
