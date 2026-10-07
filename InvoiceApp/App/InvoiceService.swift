import Foundation
import SwiftData
import InvoiceCore

/// The operations that change accounting state.
///
/// These are deliberately not in the views. Issuing an invoice consumes a number,
/// freezes the parties, and is not reversible; that is worth having in one reviewable
/// place rather than spread across button actions.
@MainActor
struct InvoiceService {
    let context: ModelContext

    // MARK: Profile

    /// Fetches the single business profile, creating it on first launch.
    func profile() -> BusinessProfile {
        let existing = try? context.fetch(FetchDescriptor<BusinessProfile>())
        if let first = existing?.first { return first }
        let created = BusinessProfile()
        context.insert(created)
        return created
    }

    // MARK: Creating

    /// Creates a draft.
    ///
    /// A draft gets a placeholder number, not a provisional one from the real sequence.
    /// That distinction matters: anything that looks like a real number would be picked
    /// up when the next invoice is issued, so two open drafts would silently push the
    /// next issued number from 0001 to 0003. The placeholder is deliberately outside the
    /// numbering format so `InvoiceNumberFormat.counter(in:year:)` ignores it.
    func createDraft(for client: Client? = nil) -> Invoice {
        let profile = profile()
        let due = Calendar.current.date(byAdding: .day,
                                        value: profile.defaultPaymentTermDays, to: .now)
        let invoice = Invoice(number: placeholderNumber(), client: client,
                              currency: profile.defaultCurrency, dueDate: due)
        invoice.paymentTerms = profile.defaultPaymentTerms
        invoice.notes = profile.defaultNotes
        context.insert(invoice)

        let item = LineItem(vatCategory: profile.defaultVATCategory,
                            vatRate: profile.defaultVATRate, position: 0)
        item.invoice = invoice
        context.insert(item)
        return invoice
    }

    /// The number a draft shows until it is issued. Unique because `Invoice.number` is
    /// a unique attribute, so a collision would overwrite another draft.
    static let placeholderPrefix = "DRAFT-"

    private func placeholderNumber() -> String {
        let taken = Set(allNumbers())
        var counter = 1
        while taken.contains("\(Self.placeholderPrefix)\(counter)") {
            counter += 1
            if counter > 100_000 { break }
        }
        return "\(Self.placeholderPrefix)\(counter)"
    }

    /// What the next issued invoice will be called, for display next to a draft.
    func nextIssuedNumber(on date: Date = .now) -> String {
        let year = Calendar.current.component(.year, from: date)
        var sequence = profile().numbering
        sequence.absorb(existingNumbers: issuedNumbers(), year: year)
        return sequence.peek(year: year)
    }

    private func allNumbers() -> [String] {
        (try? context.fetch(FetchDescriptor<Invoice>()).map(\.number)) ?? []
    }

    /// Only numbers that have actually been issued count towards the sequence. A draft's
    /// placeholder, or a number hand-typed into one, must not move the watermark.
    private func issuedNumbers() -> [String] {
        // Captured rather than inlined, so renaming the enum case cannot leave a
        // string literal here silently matching nothing.
        let draftRaw = InvoiceStatus.draft.rawValue
        let descriptor = FetchDescriptor<Invoice>(
            predicate: #Predicate { $0.statusRaw != draftRaw })
        return (try? context.fetch(descriptor).map(\.number)) ?? []
    }

    // MARK: Issuing

    enum IssueError: Error, LocalizedError {
        case notADraft
        case blocked([ValidationIssue])

        var errorDescription: String? {
            switch self {
            case .notADraft:
                return "This invoice has already been issued."
            case .blocked(let issues):
                return "The invoice is not ready to issue:\n"
                    + issues.filter { $0.severity == .error }
                        .map { "• \($0.message)" }.joined(separator: "\n")
            }
        }
    }

    /// Issues a draft: validates it, consumes the next number in the sequence, and
    /// freezes the parties onto the record.
    @discardableResult
    func issue(_ invoice: Invoice) throws -> Invoice {
        guard invoice.status == .draft else { throw IssueError.notADraft }

        let profile = profile()
        let issues = InvoiceValidator().validate(invoice.document(profile: profile))
        if InvoiceValidator().blocksExport(issues) { throw IssueError.blocked(issues) }

        var sequence = profile.numbering
        let year = Calendar.current.component(.year, from: invoice.issueDate)
        sequence.absorb(existingNumbers: issuedNumbers(), year: year)
        invoice.number = sequence.issue(year: year)
        profile.numbering = sequence

        invoice.captureSnapshots(profile: profile)
        invoice.status = .issued
        return invoice
    }

    func markPaid(_ invoice: Invoice, on date: Date = .now) {
        invoice.status = .paid
        invoice.paidDate = date
    }

    func reopen(_ invoice: Invoice) {
        guard invoice.status == .paid else { return }
        invoice.status = .issued
    }

    /// An issued invoice is a record. Cancelling marks it rather than deleting it, so
    /// the sequence keeps no holes and the audit trail survives.
    func cancel(_ invoice: Invoice) {
        invoice.status = .cancelled
    }

    /// Creates a credit note reversing an issued invoice.
    ///
    /// Amounts stay positive: under EN 16931 it is the document type code (381) that
    /// signals the reversal, not a negative total. A credit note with negative lines is
    /// a common and rejected mistake.
    func createCreditNote(for invoice: Invoice) -> Invoice {
        let note = Invoice(number: placeholderNumber(),
                           client: invoice.client, currency: invoice.currency)
        note.kind = .creditNote
        note.precedingInvoiceNumber = invoice.number
        note.buyerReference = invoice.buyerReference
        note.exemptionReasons = invoice.exemptionReasons
        note.paymentTerms = ""
        note.notes = "Credit note for invoice \(invoice.number)."
        context.insert(note)

        for (index, item) in invoice.items.sorted(by: { $0.position < $1.position }).enumerated() {
            let copy = LineItem(details: item.details, quantity: item.quantity,
                                unitCode: item.unitCode, unitPrice: item.unitPriceValue,
                                vatCategory: item.vatCategory, vatRate: item.vatRate,
                                position: index)
            copy.note = item.note
            copy.discountValue = item.discountValue
            copy.invoice = note
            context.insert(copy)
        }
        return note
    }

    /// Copies an invoice into a fresh draft, which is how most recurring work is billed.
    func duplicate(_ invoice: Invoice) -> Invoice {
        let draft = createDraft(for: invoice.client)
        // createDraft seeds one blank line; remove it before copying the real ones.
        for item in draft.items { context.delete(item) }
        draft.items.removeAll()

        draft.currencyCode = invoice.currencyCode
        draft.paymentTerms = invoice.paymentTerms
        draft.notes = invoice.notes
        draft.buyerReference = invoice.buyerReference
        draft.paymentMeans = invoice.paymentMeans
        draft.exemptionReasons = invoice.exemptionReasons

        for (index, item) in invoice.items.sorted(by: { $0.position < $1.position }).enumerated() {
            let copy = LineItem(details: item.details, quantity: item.quantity,
                                unitCode: item.unitCode, unitPrice: item.unitPriceValue,
                                vatCategory: item.vatCategory, vatRate: item.vatRate,
                                position: index)
            copy.note = item.note
            copy.discountValue = item.discountValue
            copy.invoice = draft
            context.insert(copy)
        }
        return draft
    }

    // MARK: Deleting

    /// Deletes rows safely.
    ///
    /// The bug this replaces: `offsets.forEach { context.delete(array[$0]) }` reads the
    /// array again after the first delete has already mutated it, so the second index
    /// points at the wrong row. Resolving the objects up front avoids that entirely.
    func delete<T: PersistentModel>(_ objects: [T]) {
        for object in objects { context.delete(object) }
    }

    /// An issued invoice should be cancelled, not deleted. Drafts are fair game.
    func canDelete(_ invoice: Invoice) -> Bool { invoice.status == .draft }

    func deleteLines(_ lines: [LineItem], from invoice: Invoice) {
        let doomed = Set(lines.map(\.persistentModelID))
        invoice.items.removeAll { doomed.contains($0.persistentModelID) }
        for line in lines { context.delete(line) }
        renumberPositions(invoice)
    }

    func renumberPositions(_ invoice: Invoice) {
        for (index, item) in invoice.items.sorted(by: { $0.position < $1.position }).enumerated() {
            item.position = index
        }
    }

    func addLine(to invoice: Invoice) -> LineItem {
        let profile = profile()
        let next = (invoice.items.map(\.position).max() ?? -1) + 1
        let item = LineItem(vatCategory: profile.defaultVATCategory,
                            vatRate: profile.defaultVATRate, position: next)
        item.invoice = invoice
        context.insert(item)
        return item
    }
}
