//
//  AdminEventEditorView.swift
//  photobooth
//
//  Small internal/admin event configuration screen — proves an event can be
//  changed without editing Swift or rebuilding. Deliberately not part of the
//  guest flow (see ContentView for its hidden entry point) and has no
//  authentication yet, by explicit instruction.
//
//  Pricing controls only appear for operating modes that allow guest
//  payment (self-serve/hybrid); sponsored/promotional hide them entirely,
//  and EventPolicy.validate() is run before every save regardless, so this
//  view can't persist an invalid (e.g. sponsored + paid) configuration.
//

import SwiftUI

struct AdminEventEditorView: View {
    let store: EventConfigurationStore
    let onSaved: (EventConfiguration) -> Void
    let onCancel: () -> Void

    @State private var draft: EventConfiguration
    @State private var priceText: [BoothProduct: String]
    @State private var socialCTAEnabled: Bool
    @State private var validationErrors: [EventConfigurationValidationError] = []
    @State private var saveError: String?
    private let existingEvents: [EventConfiguration]

    private static let hubExperienceOptions: [BoothExperience] = [.classic, .arParty, .loopClip]
    private static let retentionOptions: [MediaRetentionPolicy] = [.hours(24), .hours(72), .days(7)]

    init(store: EventConfigurationStore, current: EventConfiguration?, onSaved: @escaping (EventConfiguration) -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.onSaved = onSaved
        self.onCancel = onCancel
        self.existingEvents = store.listConfigurations()
        let initial = current ?? Self.blankConfiguration()
        _draft = State(initialValue: initial)
        _priceText = State(initialValue: Self.priceTextMap(for: initial))
        _socialCTAEnabled = State(initialValue: initial.socialCTA != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !existingEvents.isEmpty {
                    Section("Load Existing Event") {
                        Picker("Event", selection: Binding(
                            get: { draft.id },
                            set: { newID in
                                if let match = existingEvents.first(where: { $0.id == newID }) {
                                    load(match)
                                }
                            }
                        )) {
                            ForEach(existingEvents) { event in
                                Text(event.name.isEmpty ? "Untitled Event" : event.name).tag(event.id)
                            }
                        }
                        Button("Start New Blank Event") { load(Self.blankConfiguration()) }
                    }
                }

                Section("Event") {
                    TextField("Event Name", text: $draft.name)
                    Picker("Operating Mode", selection: $draft.operatingMode) {
                        Text("Sponsored").tag(EventOperatingMode.sponsored)
                        Text("Self-Serve").tag(EventOperatingMode.selfServe)
                        Text("Hybrid").tag(EventOperatingMode.hybrid)
                        Text("Promotional").tag(EventOperatingMode.promotional)
                    }
                }

                Section("Experiences") {
                    ForEach(Self.hubExperienceOptions, id: \.self) { experience in
                        Toggle(experience.title, isOn: Binding(
                            get: { draft.availableExperiences.contains(experience) },
                            set: { isOn in
                                if isOn, !draft.availableExperiences.contains(experience) {
                                    draft.availableExperiences.append(experience)
                                } else if !isOn {
                                    draft.availableExperiences.removeAll { $0 == experience }
                                }
                            }
                        ))
                    }
                }

                Section("Delivery & Printing") {
                    Toggle("Digital Delivery Enabled", isOn: $draft.digitalDeliveryEnabled)
                    Toggle("Printing Enabled", isOn: $draft.printingEnabled)
                    if draft.printingEnabled {
                        Toggle("Printing Included For Guests", isOn: $draft.printingIncludedForGuests)
                    }
                }

                if draft.operatingMode == .selfServe || draft.operatingMode == .hybrid {
                    Section("Pricing (USD)") {
                        ForEach(BoothProduct.allCases, id: \.self) { product in
                            HStack {
                                Text(productLabel(product))
                                Spacer()
                                TextField("0.00", text: Binding(
                                    get: { priceText[product] ?? "" },
                                    set: { priceText[product] = $0 }
                                ))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            }
                        }
                    }
                } else {
                    Section("Pricing") {
                        Text("Guests are never charged in this operating mode, so pricing isn't editable here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Social") {
                    Toggle("Enable Social CTA", isOn: $socialCTAEnabled)
                    if socialCTAEnabled {
                        TextField("Display Name (e.g. @venue)", text: Binding(
                            get: { draft.socialCTA?.displayName ?? "" },
                            set: { setSocialCTA(\.displayName, $0) }
                        ))
                        TextField("Profile URL", text: Binding(
                            get: { draft.socialCTA?.profileURL.absoluteString ?? "" },
                            set: { text in
                                guard let url = URL(string: text) else { return }
                                setSocialCTA(\.profileURL, url)
                            }
                        ))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        TextField("Message", text: Binding(
                            get: { draft.socialCTA?.message ?? "" },
                            set: { setSocialCTA(\.message, $0) }
                        ))
                    }
                }

                Section("Retention") {
                    Picker("Media Retention", selection: $draft.mediaRetentionPolicy) {
                        ForEach(Self.retentionOptions, id: \.self) { policy in
                            Text(retentionLabel(policy)).tag(policy)
                        }
                    }
                }

                Section("Theme") {
                    TextField("Display Title", text: $draft.theme.displayTitle)
                    TextField("Display Subtitle", text: $draft.theme.displaySubtitle)
                    TextField("Primary Color (#RRGGBB)", text: $draft.theme.primaryColorHex)
                    TextField("Secondary Color (#RRGGBB)", text: $draft.theme.secondaryColorHex)
                    TextField("Accent Color (#RRGGBB)", text: $draft.theme.accentColorHex)
                    TextField("Design Notes", text: $draft.theme.designNotes, axis: .vertical)
                }

                #if DEBUG
                Section("Development Starter Templates") {
                    Button("Load Sponsored Template") { load(DevelopmentEventConfigurations.sponsored) }
                    Button("Load Self-Serve Template") { load(DevelopmentEventConfigurations.selfServe) }
                    Button("Load Hybrid Template") { load(DevelopmentEventConfigurations.hybrid) }
                    Button("Load Promotional Template") { load(DevelopmentEventConfigurations.promotional) }
                }
                #endif

                if !validationErrors.isEmpty {
                    Section("Cannot Save") {
                        ForEach(Array(validationErrors.enumerated()), id: \.offset) { _, error in
                            Text(error.errorDescription ?? "Invalid configuration.")
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                }
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Event Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func productLabel(_ product: BoothProduct) -> String {
        switch product {
        case .digitalPhoto: "Digital Photo"
        case .loopVideo: "Loop"
        case .print4x6: "Print 4x6"
        case .digitalAndPrint: "Digital + Print"
        }
    }

    private func retentionLabel(_ policy: MediaRetentionPolicy) -> String {
        switch policy {
        case .hours(let count): "\(count) Hours"
        case .days(let count): "\(count) Days"
        }
    }

    private func setSocialCTA<Value>(_ keyPath: WritableKeyPath<SocialCTA, Value>, _ value: Value) {
        var cta = draft.socialCTA ?? SocialCTA(platform: .instagram, displayName: "", profileURL: URL(string: "https://example.com")!, message: "")
        cta[keyPath: keyPath] = value
        draft.socialCTA = cta
    }

    private func load(_ configuration: EventConfiguration) {
        draft = configuration
        priceText = Self.priceTextMap(for: configuration)
        socialCTAEnabled = configuration.socialCTA != nil
        validationErrors = []
        saveError = nil
    }

    private func save() {
        var toSave = draft
        if draft.operatingMode == .selfServe || draft.operatingMode == .hybrid {
            var pricing: [BoothProduct: Money] = [:]
            for product in BoothProduct.allCases {
                let dollars = Double(priceText[product] ?? "") ?? 0
                pricing[product] = Money(amountInMinorUnits: Int((dollars * 100).rounded()), currencyCode: "USD")
            }
            toSave.productPricing = pricing
        } else {
            // Sponsored/promotional: pricing is never guest-facing, so
            // there's nothing meaningful to persist here regardless of
            // whatever the fields last showed.
            toSave.productPricing = [:]
        }
        toSave.socialCTA = socialCTAEnabled ? draft.socialCTA : nil

        let errors = EventPolicy.validate(toSave)
        guard errors.isEmpty else {
            validationErrors = errors
            return
        }
        validationErrors = []

        do {
            try store.save(toSave)
            try store.setActive(toSave.id)
            onSaved(toSave)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func blankConfiguration() -> EventConfiguration {
        EventConfiguration(
            id: UUID(),
            name: "",
            operatingMode: .sponsored,
            availableExperiences: [.classic, .arParty, .loopClip],
            productPricing: [:],
            printingEnabled: false,
            printingIncludedForGuests: false,
            digitalDeliveryEnabled: true,
            socialCTA: nil,
            mediaRetentionPolicy: .hours(24),
            theme: .none
        )
    }

    private static func priceTextMap(for configuration: EventConfiguration) -> [BoothProduct: String] {
        var map: [BoothProduct: String] = [:]
        for product in BoothProduct.allCases {
            let money = configuration.productPricing[product] ?? .free()
            map[product] = money.isFree ? "" : String(format: "%.2f", Double(money.amountInMinorUnits) / 100)
        }
        return map
    }
}
