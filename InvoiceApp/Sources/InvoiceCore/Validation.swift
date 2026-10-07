import Foundation

public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(rule)|\(message)" }
    /// The EN 16931 business rule, where one applies, e.g. "BR-06".
    public let rule: String
    public let severity: Severity
    public let message: String
    /// A hint at which part of the editor to fix.
    public let field: String?

    public init(rule: String, severity: Severity, message: String, field: String? = nil) {
        self.rule = rule
        self.severity = severity
        self.message = message
        self.field = field
    }
}

/// Pre-flight checks before export.
///
/// This is a useful subset of the EN 16931 business rules — the ones a freelancer
/// actually trips over — not the full rule set. Passing this does not certify an
/// invoice; it catches the failures that would otherwise come back from a buyer's
/// platform days later. The full Schematron check belongs in CI (see README).
public struct InvoiceValidator {
    public init() {}

    public func validate(_ invoice: InvoiceDocument, profile: FacturXProfile = .en16931) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let totals = invoice.totals

        func require(_ condition: Bool, _ rule: String, _ message: String, _ field: String? = nil) {
            if !condition { issues.append(ValidationIssue(rule: rule, severity: .error, message: message, field: field)) }
        }
        func warn(_ condition: Bool, _ message: String, _ field: String? = nil) {
            if !condition { issues.append(ValidationIssue(rule: "—", severity: .warning, message: message, field: field)) }
        }

        // Identification and dates
        require(!invoice.number.trimmingCharacters(in: .whitespaces).isEmpty,
                "BR-02", "The invoice needs a number.", "number")
        require(invoice.lines.isEmpty == false,
                "BR-16", "An invoice needs at least one line.", "lines")

        // Seller identity
        require(!invoice.seller.name.trimmingCharacters(in: .whitespaces).isEmpty,
                "BR-06", "Your business name is missing.", "seller.name")
        require(!invoice.seller.address.countryCode.isEmpty,
                "BR-09", "Your country code is missing.", "seller.address")
        require(invoice.seller.address.countryCode.count == 2 || invoice.seller.address.countryCode.isEmpty,
                "BR-CL-14", "Your country must be a two-letter ISO code.", "seller.address")

        // Buyer identity
        require(!invoice.buyer.name.trimmingCharacters(in: .whitespaces).isEmpty,
                "BR-07", "The client's name is missing.", "buyer.name")
        require(!invoice.buyer.address.countryCode.isEmpty,
                "BR-11", "The client's country code is missing.", "buyer.address")

        // Currency
        require(invoice.currency.code.count == 3,
                "BR-05", "The currency must be a three-letter ISO code.", "currency")

        // Lines
        for (index, line) in invoice.lines.enumerated() {
            let position = index + 1
            require(!line.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    "BR-25", "Line \(position) has no description.", "lines")
            require(line.quantity != 0,
                    "BR-22", "Line \(position) has a quantity of zero.", "lines")
            require(line.unitPrice.currency == invoice.currency,
                    "BR-CL-05", "Line \(position) is priced in \(line.unitPrice.currency.code), "
                        + "but the invoice is in \(invoice.currency.code).", "lines")
            if line.vatCategory.requiresExemptionReason && line.vatRate != 0 {
                issues.append(ValidationIssue(
                    rule: "BR-E-05",
                    severity: .error,
                    message: "Line \(position) is \(line.vatCategory.label.lowercased()) but carries a "
                        + "\(line.vatRate.rateString)% rate. The rate must be zero.",
                    field: "lines"))
            }
            if line.vatCategory == .standard && line.vatRate == 0 {
                warn(false, "Line \(position) is standard-rated at 0%. If that is deliberate, "
                        + "pick a zero-rated or exempt category instead so the reason is stated.", "lines")
            }
            warn(line.quantity >= 0, "Line \(position) has a negative quantity. Use a credit note instead.", "lines")
        }

        // VAT breakdown and exemption reasons
        for row in totals.breakdown where row.category.requiresExemptionReason {
            require(row.exemptionReason?.isEmpty == false,
                    "BR-E-10", "\(row.category.label) needs a stated reason on the invoice.", "vat")
        }

        // Reverse charge needs both parties VAT-registered.
        let hasReverseCharge = invoice.lines.contains { $0.vatCategory == .reverseCharge }
        if hasReverseCharge {
            require(!invoice.seller.vatID.isEmpty,
                    "BR-AE-02", "Reverse charge requires your VAT number.", "seller.vatID")
            require(!invoice.buyer.vatID.isEmpty,
                    "BR-AE-03", "Reverse charge requires the client's VAT number.", "buyer.vatID")
        }

        // If any VAT is charged at all, the seller must be identified for VAT.
        if !totals.taxTotal.isZero {
            require(!invoice.seller.vatID.isEmpty || !invoice.seller.taxRegistrationID.isEmpty,
                    "BR-S-02", "You are charging VAT, so your VAT number is required.", "seller.vatID")
        }

        // Payment
        if invoice.paymentMeans == .creditTransfer || invoice.paymentMeans == .sepaCreditTransfer {
            require(!invoice.bank.iban.isEmpty,
                    "BR-61", "Bank transfer is selected, so an IBAN is required.", "bank")
        }
        if !invoice.bank.iban.isEmpty {
            warn(IBAN.isPlausible(invoice.bank.iban),
                 "That IBAN does not pass its checksum. Worth re-reading before you send.", "bank")
        }

        // Dates
        if let due = invoice.dueDate {
            warn(due >= invoice.issueDate, "The due date is before the issue date.", "dueDate")
        } else {
            warn(!invoice.paymentTerms.isEmpty,
                 "No due date and no payment terms. Most buyers need one of the two.", "dueDate")
        }

        // Credit notes
        if invoice.kind == .creditNote {
            require(invoice.precedingInvoiceNumber?.isEmpty == false,
                    "BR-55", "A credit note must reference the invoice it corrects.", "preceding")
        }

        // Profile
        if !profile.isEN16931Compliant {
            warn(false, "The \(profile.conformanceLevel) profile is not EN 16931 compliant and will be "
                    + "rejected where e-invoicing is mandatory. Use Basic or EN 16931.", "profile")
        }

        return issues.sorted { ($0.severity, $0.rule) > ($1.severity, $1.rule) }
    }

    public func blocksExport(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }
}

/// IBAN checksum, as a typo catcher rather than a validity guarantee.
public enum IBAN {
    public static func isPlausible(_ raw: String) -> Bool {
        let s = raw.replacingOccurrences(of: " ", with: "").uppercased()
        guard s.count >= 15, s.count <= 34 else { return false }
        guard s.prefix(2).allSatisfy(\.isLetter), s.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }

        // Move the first four characters to the end, map letters to 2-digit numbers,
        // then the whole thing mod 97 must be 1.
        let rearranged = s.dropFirst(4) + s.prefix(4)
        var remainder = 0
        for character in rearranged {
            let chunk: String
            if character.isNumber {
                chunk = String(character)
            } else if let ascii = character.asciiValue, character.isLetter {
                chunk = String(Int(ascii - 65) + 10)
            } else {
                return false
            }
            for digit in chunk {
                remainder = (remainder * 10 + Int(String(digit))!) % 97
            }
        }
        return remainder == 1
    }
}
