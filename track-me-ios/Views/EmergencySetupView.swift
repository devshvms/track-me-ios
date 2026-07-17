import SwiftUI

struct EmergencySetupView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("Emergency Contacts")
                .font(.title)
                .bold()
                
            Text("Coming soon...")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .navigationTitle("Emergency Setup")
    }
}
