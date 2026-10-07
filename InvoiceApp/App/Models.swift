import Foundation
import SwiftData
import InvoiceCore

/// The persisted store.
///
/// Local-first by design: a single SwiftData store in the app's support directory, no
/// account, no server. That is a product decision as much as a technical one — the
/// market's native Mac apps compete on exactly this against the cloud suites — and it
/// also means invoice data never leaves the machine unless the user exports it.
///
/// These entities are storage, not logic. Everything that computes or validates lives
/// in InvoiceCore and operates on `InvoiceDocument` values, so none of it depends on a
/// live model context.

@Model
final class BusinessProfile {
    /// There is exactly one of these. SwiftData has no singleton, so the app fetches
    /// the first and creates one if the store is empty.
    var name: String
    var contactName: String
    var email: String
    var phone: String
    var addressLine1: String
    var addressLine2: String
    var city: String
    var postcode: String
    var countryCode: String
    var vatID: String
    var taxRegistrationID: String
    var legalRegistrationID: String

    var bankAccountName: String
    var bankIBAN: String
    var bankBIC: String

    var defaultCurrencyCode: String
    var defaultVATRate: Decimal
    var defaultVATCategoryRaw: String
    var defaultPaymentTermDays: Int
    var defaultPaymentTerms: String
    var defaultNotes: String

    /// Numbering state, stored as JSON so the sequence type stays in InvoiceCore and
    /// can gain fields without a schema migration.
    var numberingData: Data?

    /// Logo for the printed page, as PNG or JPEG data.
    @Attribute(.externalStorage) var logo: Data?

    init() {
        name = ""
        contactName = ""
        email = ""
        phone = ""
        addressLine1 = ""
        addressLine2 = ""
        city = ""
        postcode = ""
        countryCode = Locale.current.region?.identifier ?? ""
        vatID = ""
        taxRegistrationID = ""
        legalRegistrationID = ""
        bankAccountName = ""
        bankIBAN = ""
        bankBIC = ""
        defaultCurrencyCode = Locale.current.currency?.identifier ?? "EUR"
        defaultVATRate = 0
        defaultVATCategoryRaw = VATCategory.standard.rawValue
        defaultPaymentTermDays = 30
        defaultPaymentTerms = "Net 30 days"
        defaultNotes = ""
        numberingData = nil
        logo = nil
    }

    var defaultCurrency: Currency { Currency.named(defaultCurrencyCode) }

    var defaultVATCategory: VATCategory {
        get { VATCategory(rawValue: defaultVATCategoryRaw) ?? .standard }
        set { defaultVATCategoryRaw = newValue.rawValue }
    }

    var numbering: InvoiceNumberSequence {
        get {
            guard let numberingData,
                  let decoded = try? JSONDecoder().decode(InvoiceNumberSequence.self, from: numberingData)
            else { return InvoiceNumberSequence() }
            return decoded
        }
        set { numberingData = try? JSONEncoder().encode(newValue) }
    }

    var party: TradeParty {
        TradeParty(
            name: name, contactName: contactName, email: email, phone: phone,
            address: PostalAddress(line1: addressLine1, line2: addressLine2, city: city,
                                   postcode: postcode, countryCode: countryCode),
            vatID: vatID, taxRegistrationID: taxRegistrationID,
            legalRegistrationID: legalRegistrationID)
    }

    var bank: BankDetails {
        BankDetails(accountName: bankAccountName.isEmpty ? name : bankAccountName,
                    iban: bankIBAN, bic: bankBIC)
    }

    /// True until the user has filled in enough to issue a legal invoice.
    var needsSetup: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty || countryCode.isEmpty
    }
}

@Model
final class Client {
    var name: String
    var contactName: String
    var email: String
    var phone: String
    var addressLine1: String
    var addressLine2: String
    var city: String
    var postcode: String
    var countryCode: String
    var vatID: String
    var legalRegistrationID: String
    /// Default buyer reference, e.g. a standing PO number.
    var defaultBuyerReference: String
    var notes: String

    /// Nullify rather than cascade: deleting a client must never delete the invoices
    /// issued to them. Those are accounting records with a retention period.
    @Relationship(deleteRule: .nullify, inverse: \Invoice.client)
    var invoices: [Invoice] = []

    init(name: String = "") {
        self.name = name
        contactName = ""
        email = ""
        phone = ""
        addressLine1 = ""
        addressLine2 = ""
        city = ""
        postcode = ""
        countryCode = ""
        vatID = ""
        legalRegistrationID = ""
        defaultBuyerReference = ""
        notes = ""
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Unnamed client" : name
    }

    var party: TradeParty {
        TradeParty(
            name: name, contactName: contactName, email: email, phone: phone,
            address: PostalAddress(line1: addressLine1, line2: addressLine2, city: city,
                                   postcode: postcode, countryCode: countryCode),
            vatID: vatID, legalRegistrationID: legalRegistrationID)
    }

    /// Outstanding balance across this client's unpaid invoices.
    func outstanding(currency: Currency) -> Money {
        let unpaid = invoices.filter { $0.status != .paid && $0.status != .cancelled }
        return Money.sum(unpaid.compactMap { invoice in
            invoice.currency == currency ? invoice.document.totals.duePayable : nil
        }, currency: currency)
    }
}

enum InvoiceStatus: String, CaseIterable, Identifiable, Codable {
    case draft, issued, paid, cancelled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: return "Draft"
        case .issued: return "Issued"
        case .paid: return "Paid"
        case .cancelled: return "Cancelled"
        }
    }

    /// A draft may be edited and renumbered freely. Once issued, the number is spent
    /// and the document is a record: it is corrected with a credit note, not an edit.
    var isEditable: Bool { self == .draft }
}

@Model
final class Invoice {
    /// Unique so two windows cannot both issue the same number.
    @Attribute(.unique) var number: String
    var kindRaw: String
    var statusRaw: String
    var issueDate: Date
    var dueDate: Date?
    var deliveryDate: Date?
    var currencyCode: String
    var notes: String
    var paymentTerms: String
    var buyerReference: String
    var paymentMeansRaw: String
    var precedingInvoiceNumber: String?
    var prepaidAmountValue: Decimal
    var exemptionReasonData: Data?
    /// When the invoice was marked paid, for the ageing report.
    var paidDate: Date?
    var createdAt: Date

    /// A snapshot of the seller and buyer as they were when the invoice was issued.
    /// An invoice is a record of a transaction: if the client later moves office, the
    /// issued invoice must still show the address it was sent to.
    var sellerSnapshotData: Data?
    var buyerSnapshotData: Data?
    var bankSnapshotData: Data?

    var client: Client?

    @Relationship(deleteRule: .cascade, inverse: \LineItem.invoice)
    var items: [LineItem] = []

    init(number: String, client: Client? = nil, currency: Currency = .eur,
         issueDate: Date = .now, dueDate: Date? = nil) {
        self.number = number
        kindRaw = DocumentKind.invoice.rawValue
        statusRaw = InvoiceStatus.draft.rawValue
        self.issueDate = issueDate
        self.dueDate = dueDate
        deliveryDate = issueDate
        currencyCode = currency.code
        notes = ""
        paymentTerms = ""
        buyerReference = client?.defaultBuyerReference ?? ""
        paymentMeansRaw = PaymentMeans.creditTransfer.rawValue
        precedingInvoiceNumber = nil
        prepaidAmountValue = 0
        exemptionReasonData = nil
        paidDate = nil
        createdAt = .now
        self.client = client
    }

    var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRaw) ?? .invoice }
        set { kindRaw = newValue.rawValue }
    }

    var status: InvoiceStatus {
        get { InvoiceStatus(rawValue: statusRaw) ?? .draft }
        set {
            statusRaw = newValue.rawValue
            paidDate = newValue == .paid ? (paidDate ?? .now) : nil
        }
    }

    var currency: Currency { Currency.named(currencyCode) }

    var paymentMeans: PaymentMeans {
        get { PaymentMeans(rawValue: paymentMeansRaw) ?? .creditTransfer }
        set { paymentMeansRaw = newValue.rawValue }
    }

    var exemptionReasons: [VATCategory: String] {
        get {
            guard let exemptionReasonData,
                  let raw = try? JSONDecoder().decode([String: String].self, from: exemptionReasonData)
            else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                VATCategory(rawValue: key).map { ($0, value) }
            })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            exemptionReasonData = try? JSONEncoder().encode(raw)
        }
    }

    private func snapshot<T: Codable>(_ data: Data?, as type: T.Type) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The seller as recorded on this invoice, falling back to the live profile for a
    /// draft that has not been issued yet.
    func seller(fallback: BusinessProfile?) -> TradeParty {
        snapshot(sellerSnapshotData, as: TradeParty.self) ?? fallback?.party ?? TradeParty()
    }

    func buyer() -> TradeParty {
        snapshot(buyerSnapshotData, as: TradeParty.self) ?? client?.party ?? TradeParty()
    }

    func bank(fallback: BusinessProfile?) -> BankDetails {
        snapshot(bankSnapshotData, as: BankDetails.self) ?? fallback?.bank ?? BankDetails()
    }

    /// Freezes the parties onto the invoice. Called once, when the invoice is issued.
    func captureSnapshots(profile: BusinessProfile?) {
        sellerSnapshotData = try? JSONEncoder().encode(profile?.party ?? TradeParty())
        buyerSnapshotData = try? JSONEncoder().encode(client?.party ?? TradeParty())
        bankSnapshotData = try? JSONEncoder().encode(profile?.bank ?? BankDetails())
    }

    /// The value type everything else works on. `profile` is only consulted for a draft
    /// that has no snapshot yet.
    func document(profile: BusinessProfile? = nil) -> InvoiceDocument {
        let currency = self.currency
        return InvoiceDocument(
            kind: kind,
            number: number,
            issueDate: issueDate,
            dueDate: dueDate,
            deliveryDate: deliveryDate,
            currency: currency,
            seller: seller(fallback: profile),
            buyer: buyer(),
            lines: items.sorted { $0.position < $1.position }.map { $0.line(currency: currency) },
            paymentMeans: paymentMeans,
            bank: bank(fallback: profile),
            paymentTerms: paymentTerms,
            notes: notes,
            exemptionReasons: exemptionReasons,
            buyerReference: buyerReference,
            precedingInvoiceNumber: precedingInvoiceNumber,
            prepaidAmount: prepaidAmountValue == 0 ? nil : Money(prepaidAmountValue, currency))
    }

    /// Convenience for views that do not hold the profile.
    var document: InvoiceDocument { document(profile: nil) }

    var isOverdue: Bool {
        guard status == .issued, let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: .now)
    }

    var daysOverdue: Int {
        guard isOverdue, let dueDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: dueDate, to: .now).day ?? 0
    }
}

@Model
final class LineItem {
    var details: String
    var note: String
    var quantity: Decimal
    var unitCode: String
    var unitPriceValue: Decimal
    var vatCategoryRaw: String
    var vatRate: Decimal
    var discountValue: Decimal
    /// Explicit ordering: a SwiftData relationship array has no guaranteed order, and
    /// the order of lines on an invoice is visible to the customer.
    var position: Int

    var invoice: Invoice?

    init(details: String = "", quantity: Decimal = 1, unitCode: String = "C62",
         unitPrice: Decimal = 0, vatCategory: VATCategory = .standard,
         vatRate: Decimal = 0, position: Int = 0) {
        self.details = details
        note = ""
        self.quantity = quantity
        self.unitCode = unitCode
        unitPriceValue = unitPrice
        vatCategoryRaw = vatCategory.rawValue
        self.vatRate = vatRate
        discountValue = 0
        self.position = position
    }

    var vatCategory: VATCategory {
        get { VATCategory(rawValue: vatCategoryRaw) ?? .standard }
        set {
            vatCategoryRaw = newValue.rawValue
            // A category that charges no VAT cannot carry a rate; clear it here so the
            // stored row can never contradict itself.
            if newValue.requiresExemptionReason { vatRate = 0 }
        }
    }

    func line(currency: Currency) -> InvoiceLine {
        InvoiceLine(
            name: details, note: note, quantity: quantity, unitCode: unitCode,
            unitPrice: Money(unitPriceValue, currency),
            vatCategory: vatCategory, vatRate: vatRate,
            discount: discountValue == 0 ? nil : Money(discountValue, currency))
    }

    func total(currency: Currency) -> Money { line(currency: currency).netAmount }
}
