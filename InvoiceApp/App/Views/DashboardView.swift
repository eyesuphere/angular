import SwiftUI
import SwiftData
import InvoiceCore

/// What a freelancer actually opens the app to find out: who owes me, and how late.
struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Invoice.issueDate, order: .reverse) private var invoices: [Invoice]

    private var profile: BusinessProfile { InvoiceService(context: context).profile() }
    private var currency: Currency { profile.defaultCurrency }

    /// Only invoices in the default currency are summed. Mixing currencies into one
    /// figure would need an exchange rate the app does not have, and a wrong total here
    /// is worse than an absent one.
    private var relevant: [Invoice] { invoices.filter { $0.currency == currency } }

    private var outstanding: Money {
        Money.sum(relevant.filter { $0.status == .issued }
            .map { $0.document.totals.duePayable }, currency: currency)
    }

    private var overdue: Money {
        Money.sum(relevant.filter(\.isOverdue)
            .map { $0.document.totals.duePayable }, currency: currency)
    }

    private var paidThisYear: Money {
        let year = Calendar.current.component(.year, from: .now)
        return Money.sum(relevant.filter {
            $0.status == .paid && Calendar.current.component(.year, from: $0.issueDate) == year
        }.map { $0.document.totals.grandTotal }, currency: currency)
    }

    private var drafts: Int { invoices.filter { $0.status == .draft }.count }

    private var excludedCount: Int { invoices.count - relevant.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    tile("Outstanding", outstanding, tone: .primary)
                    tile("Overdue", overdue, tone: overdue.isZero ? .primary : .warning)
                    tile("Paid this year", paidThisYear, tone: .primary)
                }

                if drafts > 0 {
                    Label("\(drafts) draft\(drafts == 1 ? "" : "s") not yet issued",
                          systemImage: "pencil.circle")
                        .foregroundStyle(.secondary)
                }

                if excludedCount > 0 {
                    Label("\(excludedCount) invoice\(excludedCount == 1 ? "" : "s") in another "
                          + "currency are not included in these totals.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                overdueSection

                if invoices.isEmpty {
                    ContentUnavailableView(
                        "No invoices yet", systemImage: "doc.text",
                        description: Text("Create your first invoice from the Invoices tab."))
                        .padding(.top, 40)
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private var overdueSection: some View {
        let late = relevant.filter(\.isOverdue).sorted { $0.daysOverdue > $1.daysOverdue }
        return Group {
            if !late.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chase these").font(.headline)
                    ForEach(late) { invoice in
                        HStack {
                            Text(invoice.number).monospacedDigit()
                            Text(invoice.client?.displayName ?? "No client")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(invoice.daysOverdue) days late")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(invoice.document.totals.duePayable.formatted())
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private enum Tone { case primary, warning }

    private func tile(_ caption: String, _ value: Money, tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tone == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
