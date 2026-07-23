import SwiftUI
import SwiftData
import MessageUI

struct EmergencySetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EmergencyContact.createdAt) private var contacts: [EmergencyContact]

    @Query private var settingsQuery: [EmergencySettings]
    @State private var messageTemplate: String = ""
    @State private var showingContactPicker = false
    @State private var showingManualEntry = false
    @State private var manualName = ""
    @State private var manualPhone = ""

    @State private var showingTestMessage = false
    @State private var showingNoSmsAlert = false

    var body: some View {
        Form {
            Section(header: Text(LocalizationHelper.localized("Emergency Contacts"))) {
                ForEach(contacts) { contact in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(contact.name).font(.headline)
                            Text(contact.phoneNumber).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(contact.medium)
                            .font(.caption)
                            .padding(4)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(LocalizationHelper.formatted("%@, %@, via %@", contact.name, contact.phoneNumber, contact.medium))
                }
                .onDelete(perform: deleteContacts)

                Button(action: { showingContactPicker = true }) {
                    Label(LocalizationHelper.localized("Add from Contacts"), systemImage: "person.crop.circle.badge.plus")
                }
                Button(action: { showingManualEntry = true }) {
                    Label(LocalizationHelper.localized("Add Manually"), systemImage: "keyboard")
                }
            }

            Section(
                header: Text(LocalizationHelper.localized("Message Template")),
                footer: Text(LocalizationHelper.localized("Placeholders: [Location Link], [Battery Percent], [Device Name], [Timestamp]"))
            ) {
                TextEditor(text: $messageTemplate)
                    .frame(minHeight: 100)

                Button(LocalizationHelper.localized("Reset to default")) {
                    messageTemplate = "EMERGENCY! I need help. My last known location is: [Location Link]. Battery: [Battery Percent]. Device: [Device Name]. Time: [Timestamp]"
                }
                .foregroundColor(.red)
            }

            Section {
                Button(LocalizationHelper.localized("Send test message")) {
                    if canSendText() {
                        showingTestMessage = true
                    } else {
                        showingNoSmsAlert = true
                    }
                }

                Button(action: saveSettings) {
                    Text(LocalizationHelper.localized("Finish setup"))
                        .frame(maxWidth: .infinity)
                        .foregroundColor((messageTemplate.isEmpty || contacts.isEmpty) ? .secondary : .white)
                }
                .listRowBackground((messageTemplate.isEmpty || contacts.isEmpty) ? Color.gray.opacity(0.3) : BrandColor.success)
                .disabled(messageTemplate.isEmpty || contacts.isEmpty)
            }
        }
        .navigationTitle(LocalizationHelper.localized("Emergency Setup"))
        .onAppear {
            loadSettings()
        }
        .sheet(isPresented: $showingContactPicker) {
            ContactPicker { name, phone in
                addContact(name: name, phone: phone)
            }
        }
        .alert(LocalizationHelper.localized("Add Contact"), isPresented: $showingManualEntry) {
            TextField(LocalizationHelper.localized("Name"), text: $manualName)
            TextField(LocalizationHelper.localized("Phone"), text: $manualPhone)
                .keyboardType(.phonePad)
            Button(LocalizationHelper.localized("Cancel"), role: .cancel) { }
            Button(LocalizationHelper.localized("Add")) {
                if !manualName.isEmpty && !manualPhone.isEmpty {
                    addContact(name: manualName, phone: manualPhone)
                    manualName = ""
                    manualPhone = ""
                }
            }
        }
        .alert(LocalizationHelper.localized("Cannot send SMS"), isPresented: $showingNoSmsAlert) {
            Button(LocalizationHelper.localized("OK"), role: .cancel) { }
        } message: {
            Text(LocalizationHelper.localized("This device cannot send SMS messages."))
        }
        .sheet(isPresented: $showingTestMessage) {
            UIDevice.current.isBatteryMonitoringEnabled = true
            MessageComposeView(
                recipients: contacts.map { $0.phoneNumber },
                body: EmergencyManager.shared.buildEmergencyMessage(
                    template: messageTemplate,
                    coordinate: TrackingManager.shared.points.last?.coordinate,
                    battery: Float(UIDevice.current.batteryLevel),
                    deviceModel: UIDevice.current.model,
                    date: Date()
                )
            )
        }
    }

    private var settings: EmergencySettings? {
        return settingsQuery.first
    }

    private func loadSettings() {
        if let settings = settings {
            self.messageTemplate = settings.messageTemplate
        } else {
            let newSettings = EmergencySettings()
            modelContext.insert(newSettings)
            try? modelContext.save()
            self.messageTemplate = newSettings.messageTemplate
        }
    }

    private func saveSettings() {
        guard let settings = settings else { return }
        settings.messageTemplate = messageTemplate
        settings.isSetupComplete = !contacts.isEmpty
        try? modelContext.save()
        ToastManager.shared.show(message: LocalizationHelper.localized("Settings saved"), style: .success)
    }

    private func addContact(name: String, phone: String) {
        let contact = EmergencyContact(name: name, phoneNumber: phone)
        modelContext.insert(contact)
        try? modelContext.save()
    }

    private func deleteContacts(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(contacts[index])
        }
        try? modelContext.save()

        if contacts.count - offsets.count == 0 {
            settings?.isSetupComplete = false
            try? modelContext.save()
        }
    }

    private func canSendText() -> Bool {
        return MFMessageComposeViewController.canSendText()
    }
}
