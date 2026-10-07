import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import InvoiceCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            ScrollView {
                BusinessProfileForm(profile: InvoiceService(context: context).profile())
                    .padding()
            }
            .tabItem { Label("Business", systemImage: "building.2") }

            ScrollView {
                NumberingForm(profile: InvoiceService(context: context).profile())
                    .padding()
            }
            .tabItem { Label("Numbering", systemImage: "number") }

            ScrollView {
                DefaultsForm(profile: InvoiceService(context: context).profile())
                    .padding()
            }
            .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
        }
    }
}

struct BusinessProfileForm: View {
    @Bindable var profile: BusinessProfile

    var body: some View {
        Form {
            Section("Your business") {
                TextField("Business name", text: $profile.name)
                TextField("Your name", text: $profile.contactName)
                TextField("Email", text: $profile.email)
                TextField("Phone", text: $profile.phone)
            }

            Section("Address") {
                TextField("Street", text: $profile.addressLine1)
                TextField("Street (second line)", text: $profile.addressLine2)
                TextField("Postcode", text: $profile.postcode)
                TextField("City", text: $profile.city)
                CountryCodeField(code: $profile.countryCode)
            }

            Section("Tax identity") {
                TextField("VAT number", text: $profile.vatID)
                    .help("Printed on every invoice and required whenever you charge VAT.")
                TextField("Tax number", text: $profile.taxRegistrationID)
                TextField("Company registration", text: $profile.legalRegistrationID)
            }

            Section("Getting paid") {
                TextField("Account name", text: $profile.bankAccountName)
                TextField("IBAN", text: $profile.bankIBAN)
                if !profile.bankIBAN.isEmpty, !IBAN.isPlausible(profile.bankIBAN) {
                    Label("That IBAN does not pass its checksum.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("BIC", text: $profile.bankBIC)
            }

            Section("Logo") {
                LogoPicker(logo: $profile.logo)
            }
        }
        .formStyle(.grouped)
    }
}

struct NumberingForm: View {
    @Bindable var profile: BusinessProfile
    @State private var format: InvoiceNumberFormat = .default

    var body: some View {
        Form {
            Section {
                TextField("Prefix", text: $format.prefix)
                Toggle("Include the year", isOn: $format.includesYear)
                Stepper("Digits: \(format.digits)", value: $format.digits, in: 1...8)
                Toggle("Restart numbering each year", isOn: $format.resetsAnnually)
            } header: {
                Text("Format")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Next number",
                                   value: profile.numbering.peek(
                                    year: Calendar.current.component(.year, from: .now)))
                        .font(.callout.bold())
                    Text("Numbers are issued in an unbroken sequence and are never reused, "
                         + "including after you delete a draft. Most tax authorities require "
                         + "that, so the counter only ever moves forward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { format = profile.numbering.format }
        .onChange(of: format) { _, new in
            var sequence = profile.numbering
            sequence.format = new
            profile.numbering = sequence
        }
    }
}

struct DefaultsForm: View {
    @Bindable var profile: BusinessProfile

    var body: some View {
        Form {
            Section("New invoices start with") {
                Picker("Currency", selection: $profile.defaultCurrencyCode) {
                    ForEach(["EUR", "USD", "GBP", "CHF", "SEK", "DKK", "NOK", "PLN",
                             "CAD", "AUD", "JPY"], id: \.self) { Text($0).tag($0) }
                }
                Picker("VAT treatment",
                       selection: Binding(get: { profile.defaultVATCategory },
                                          set: { profile.defaultVATCategory = $0 })) {
                    ForEach(VATCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if !profile.defaultVATCategory.requiresExemptionReason {
                    HStack {
                        Text("VAT rate")
                        Spacer()
                        DecimalField(title: "Rate", value: $profile.defaultVATRate)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                Stepper("Payment term: \(profile.defaultPaymentTermDays) days",
                        value: $profile.defaultPaymentTermDays, in: 0...180)
                TextField("Payment terms text", text: $profile.defaultPaymentTerms)
                TextField("Standard note", text: $profile.defaultNotes, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section {
                Text("Invoices are exported as Factur-X / ZUGFeRD at the EN 16931 profile, "
                     + "which is the format the French and German e-invoicing mandates "
                     + "require. A plain PDF export is also available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("E-invoicing")
            }
        }
        .formStyle(.grouped)
    }
}

struct LogoPicker: View {
    @Binding var logo: Data?

    var body: some View {
        HStack(spacing: 12) {
            if let logo, let image = NSImage(data: logo) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: 120, height: 48)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 120, height: 48)
                    .overlay(Text("No logo").font(.caption).foregroundStyle(.secondary))
            }

            VStack(alignment: .leading) {
                Button("Choose…") { choose() }
                if logo != nil {
                    Button("Remove", role: .destructive) { logo = nil }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Read into the store rather than keeping a path: a logo that disappears
        // because a file moved would silently change every future invoice.
        logo = try? Data(contentsOf: url)
    }
}
