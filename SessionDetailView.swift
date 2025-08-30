import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @State private var showLiveScanner = false
    @State private var mutableSession: Session
    @Environment(\.presentationMode) var presentationMode

    init(session: Session) {
        self.session = session
        self._mutableSession = State(initialValue: session)
    }

    var body: some View {
        List {
            Section(header: Text("Stored Numbers (\(mutableSession.numbers.count))")) {
                ForEach(mutableSession.numbers, id: \.self) { num in
                    HStack {
                        Text(num)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if mutableSession.collectedNumbers.contains(num) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if mutableSession.missingNumbers.contains(num) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            
            if !mutableSession.collectedNumbers.isEmpty {
                Section(header: Text("Collected Numbers (\(mutableSession.collectedNumbers.count))")) {
                    ForEach(mutableSession.collectedNumbers.sorted(), id: \.self) { num in
                        HStack {
                            Text(num)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.green)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            
            if !mutableSession.missingNumbers.isEmpty {
                Section(header: Text("Missing Numbers (\(mutableSession.missingNumbers.count))")) {
                    ForEach(mutableSession.missingNumbers.sorted(), id: \.self) { num in
                        HStack {
                            Text(num)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.red)
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            
            // Summary section
            Section(header: Text("Summary")) {
                HStack {
                    Text("Total Numbers")
                    Spacer()
                    Text("\(mutableSession.numbers.count)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Collected")
                    Spacer()
                    Text("\(mutableSession.collectedNumbers.count)")
                        .foregroundColor(.green)
                }
                
                HStack {
                    Text("Missing")
                    Spacer()
                    Text("\(mutableSession.missingNumbers.count)")
                        .foregroundColor(.red)
                }
                
                HStack {
                    Text("Completion")
                    Spacer()
                    let percentage = mutableSession.numbers.isEmpty ? 0 :
                        (Double(mutableSession.collectedNumbers.count) / Double(mutableSession.numbers.count)) * 100
                    Text(String(format: "%.0f%%", percentage))
                        .foregroundColor(percentage == 100 ? .green : .orange)
                }
            }
        }
        .navigationTitle(mutableSession.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing: Button(action: {
            showLiveScanner = true
        }) {
            HStack {
                Image(systemName: "camera.viewfinder")
                Text("Scan")
            }
        })
        .fullScreenCover(isPresented: $showLiveScanner) {
            LiveScannerView(session: $mutableSession, onComplete: { updatedSession in
                mutableSession = updatedSession
                showLiveScanner = false
                
                // Update the session in parent view
                if var sessions = UserDefaults.standard.data(forKey: "SavedSessions"),
                   var decodedSessions = try? JSONDecoder().decode([Session].self, from: sessions) {
                    if let index = decodedSessions.firstIndex(where: { $0.id == updatedSession.id }) {
                        decodedSessions[index] = updatedSession
                        if let data = try? JSONEncoder().encode(decodedSessions) {
                            UserDefaults.standard.set(data, forKey: "SavedSessions")
                        }
                    }
                }
            })
        }
    }
}
