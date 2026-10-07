import Foundation

/// VAT category codes from UNTDID 5305, restricted to the ones EN 16931 allows.
///
/// The category drives whether VAT is charged at all, and whether the invoice must
/// carry a legal explanation. A freelancer billing a client in another EU member
/// state uses `.reverseCharge`; one under a national small-business threshold uses
/// `.exempt`. Getting this wrong is the most common compliance failure, which is why
/// it is a required field rather than an inferred one.
public enum VATCategory: String, Hashable, Sendable, Codable, CaseIterable {
    case standard = "S"            // standard rate
    case zeroRated = "Z"           // zero-rated goods
    case exempt = "E"              // exempt from VAT
    case reverseCharge = "AE"      // VAT reverse charge
    case intraCommunity = "K"      // intra-community supply, zero rate
    case export = "G"              // export outside the VAT area
    case outOfScope = "O"          // not subject to VAT

    /// Categories where the rate must be zero and an exemption reason is required.
    public var requiresExemptionReason: Bool {
        switch self {
        case .standard, .zeroRated: return false
        case .exempt, .reverseCharge, .intraCommunity, .export, .outOfScope: return true
        }
    }

    /// The wording EN 16931 expects as the default exemption reason.
    public var defaultExemptionReason: String? {
        switch self {
        case .standard, .zeroRated: return nil
        case .exempt: return "Exempt from VAT"
        case .reverseCharge: return "Reverse charge: VAT to be accounted for by the recipient"
        case .intraCommunity: return "Intra-community supply, zero-rated"
        case .export: return "Export outside the VAT area, zero-rated"
        case .outOfScope: return "Not subject to VAT"
        }
    }

    public var label: String {
        switch self {
        case .standard: return "Standard rate"
        case .zeroRated: return "Zero-rated"
        case .exempt: return "Exempt"
        case .reverseCharge: return "Reverse charge"
        case .intraCommunity: return "Intra-community supply"
        case .export: return "Export"
        case .outOfScope: return "Out of scope"
        }
    }
}

/// UNTDID 1001 document type codes.
public enum DocumentKind: String, Hashable, Sendable, Codable {
    case invoice = "380"
    case creditNote = "381"
    case correctedInvoice = "384"
}

/// UNTDID 4461 payment means. Only the codes a small business realistically uses.
public enum PaymentMeans: String, Hashable, Sendable, Codable, CaseIterable {
    case notSpecified = "1"
    case cash = "10"
    case cheque = "20"
    case creditTransfer = "30"
    case directDebit = "49"
    case card = "48"
    case sepaCreditTransfer = "58"

    public var label: String {
        switch self {
        case .notSpecified: return "Not specified"
        case .cash: return "Cash"
        case .cheque: return "Cheque"
        case .creditTransfer: return "Bank transfer"
        case .directDebit: return "Direct debit"
        case .card: return "Card"
        case .sepaCreditTransfer: return "SEPA credit transfer"
        }
    }
}

public struct PostalAddress: Hashable, Sendable, Codable {
    public var line1: String
    public var line2: String
    public var city: String
    public var postcode: String
    /// ISO 3166-1 alpha-2. Required by EN 16931 for both parties.
    public var countryCode: String
    public var subdivision: String

    public init(line1: String = "", line2: String = "", city: String = "",
                postcode: String = "", countryCode: String = "", subdivision: String = "") {
        self.line1 = line1
        self.line2 = line2
        self.city = city
        self.postcode = postcode
        self.countryCode = countryCode.uppercased()
        self.subdivision = subdivision
    }

    public var isEmpty: Bool {
        line1.isEmpty && city.isEmpty && postcode.isEmpty && countryCode.isEmpty
    }

    /// Multi-line form for the printed page.
    public var displayLines: [String] {
        [line1, line2, [postcode, city].filter { !$0.isEmpty }.joined(separator: " "), countryCode]
            .filter { !$0.isEmpty }
    }
}

public struct TradeParty: Hashable, Sendable, Codable {
    public var name: String
    public var contactName: String
    public var email: String
    public var phone: String
    public var address: PostalAddress
    /// VAT identifier, e.g. "DE123456789". Mapped to schemeID "VA".
    public var vatID: String
    /// National tax/company registration, e.g. a SIRET or a Steuernummer. schemeID "FC".
    public var taxRegistrationID: String
    /// Legal registration identifier (SIREN, Handelsregisternummer) for the party.
    public var legalRegistrationID: String

    public init(name: String = "", contactName: String = "", email: String = "", phone: String = "",
                address: PostalAddress = PostalAddress(), vatID: String = "",
                taxRegistrationID: String = "", legalRegistrationID: String = "") {
        self.name = name
        self.contactName = contactName
        self.email = email
        self.phone = phone
        self.address = address
        self.vatID = vatID
        self.taxRegistrationID = taxRegistrationID
        self.legalRegistrationID = legalRegistrationID
    }
}

public struct BankDetails: Hashable, Sendable, Codable {
    public var accountName: String
    public var iban: String
    public var bic: String

    public init(accountName: String = "", iban: String = "", bic: String = "") {
        self.accountName = accountName
        self.iban = iban
        self.bic = bic
    }

    public var isEmpty: Bool { iban.isEmpty && accountName.isEmpty }
}

/// One billable line.
public struct InvoiceLine: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var note: String
    public var quantity: Decimal
    /// UN/ECE Recommendation 20 unit code. "C62" is "one/piece"; "HUR" is hours.
    public var unitCode: String
    public var unitPrice: Money
    public var vatCategory: VATCategory
    /// Percent, e.g. 19 or 8.875. Must be zero for non-standard categories.
    public var vatRate: Decimal
    /// A per-line discount, as an amount in the invoice currency.
    public var discount: Money?

    public init(id: UUID = UUID(), name: String = "", note: String = "",
                quantity: Decimal = 1, unitCode: String = "C62",
                unitPrice: Money, vatCategory: VATCategory = .standard,
                vatRate: Decimal = 0, discount: Money? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.quantity = quantity
        self.unitCode = unitCode
        self.unitPrice = unitPrice
        self.vatCategory = vatCategory
        self.vatRate = vatRate
        self.discount = discount
    }

    /// The line net amount (BT-131), rounded to the currency. EN 16931 rounds here.
    public var netAmount: Money {
        let gross = unitPrice * quantity
        let net = gross - (discount ?? Money.zero(unitPrice.currency))
        return net.rounded
    }
}

/// Common unit codes, for the picker.
public enum UnitCode {
    public static let options: [(code: String, label: String)] = [
        ("C62", "Item"), ("HUR", "Hour"), ("DAY", "Day"), ("WEE", "Week"),
        ("MON", "Month"), ("E48", "Service unit"), ("KGM", "Kilogram"), ("MTR", "Metre"),
    ]

    public static func label(for code: String) -> String {
        options.first { $0.code == code }?.label ?? code
    }
}

/// A complete invoice as a value type, independent of how it is stored.
///
/// The SwiftData entities in the app layer convert to this for export, validation and
/// rendering, so none of that logic depends on a managed object graph being alive.
public struct InvoiceDocument: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var kind: DocumentKind
    public var number: String
    public var issueDate: Date
    public var dueDate: Date?
    /// The date the goods or service were supplied (BT-72). Distinct from the issue date,
    /// and the one that determines the VAT period.
    public var deliveryDate: Date?
    public var currency: Currency
    public var seller: TradeParty
    public var buyer: TradeParty
    public var lines: [InvoiceLine]
    public var paymentMeans: PaymentMeans
    public var bank: BankDetails
    /// Free-text payment terms (BT-20).
    public var paymentTerms: String
    public var notes: String
    /// Reason text per VAT category, where the category requires one.
    public var exemptionReasons: [VATCategory: String]
    /// Buyer's purchase-order reference (BT-13). Many corporate buyers reject without it.
    public var buyerReference: String
    /// For a credit note: the invoice it corrects.
    public var precedingInvoiceNumber: String?
    /// Amount already paid (BT-113).
    public var prepaidAmount: Money?

    public init(id: UUID = UUID(), kind: DocumentKind = .invoice, number: String,
                issueDate: Date = Date(), dueDate: Date? = nil, deliveryDate: Date? = nil,
                currency: Currency = .eur, seller: TradeParty = TradeParty(),
                buyer: TradeParty = TradeParty(), lines: [InvoiceLine] = [],
                paymentMeans: PaymentMeans = .creditTransfer, bank: BankDetails = BankDetails(),
                paymentTerms: String = "", notes: String = "",
                exemptionReasons: [VATCategory: String] = [:], buyerReference: String = "",
                precedingInvoiceNumber: String? = nil, prepaidAmount: Money? = nil) {
        self.id = id
        self.kind = kind
        self.number = number
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.deliveryDate = deliveryDate
        self.currency = currency
        self.seller = seller
        self.buyer = buyer
        self.lines = lines
        self.paymentMeans = paymentMeans
        self.bank = bank
        self.paymentTerms = paymentTerms
        self.notes = notes
        self.exemptionReasons = exemptionReasons
        self.buyerReference = buyerReference
        self.precedingInvoiceNumber = precedingInvoiceNumber
        self.prepaidAmount = prepaidAmount
    }

    public var totals: InvoiceTotals { InvoiceTotals(self) }

    public func exemptionReason(for category: VATCategory) -> String? {
        guard category.requiresExemptionReason else { return nil }
        let custom = exemptionReasons[category]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return category.defaultExemptionReason
    }
}
