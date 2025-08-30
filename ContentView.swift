import SwiftUI
import Vision
import PhotosUI
import AVFoundation
import CoreHaptics

struct ContentView: View {
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showLiveScanner = false
    @State private var showManualInput = false  // New state for manual input
    @State private var imageSelections: [PhotosPickerItem] = []
    @State private var cameraImage: UIImage?
    @State private var extractedNumbers: Set<String> = []
    @State private var savedSessions: [Session] = []
    @State private var showingPrompt = false
    @State private var isEditing = false
    @State private var selectedSessions = Set<UUID>()
    @State private var currentSession: Session?
    @State private var showingAddMorePrompt = false
    
    // UserDefaults key for persistence
    private let sessionsKey = "SavedSessions"
    
    init() {
        // Load saved sessions on init
        _savedSessions = State(initialValue: loadSessions())
    }
    
    private func loadSessions() -> [Session] {
        guard let data = UserDefaults.standard.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            return []
        }
        return sessions
    }
    
    private func saveSessions() {
        if let data = try? JSONEncoder().encode(savedSessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                if savedSessions.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                        Text("No saved sessions yet.")
                            .foregroundColor(.gray)
                            .font(.headline)
                        Text("Start a new session to scan numbers")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(savedSessions) { session in
                            if isEditing {
                                HStack {
                                    Image(systemName: selectedSessions.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.purple)
                                        .onTapGesture {
                                            if selectedSessions.contains(session.id) {
                                                selectedSessions.remove(session.id)
                                            } else {
                                                selectedSessions.insert(session.id)
                                            }
                                        }
                                    VStack(alignment: .leading) {
                                        Text(session.name)
                                            .font(.headline)
                                        Text("\(session.numbers.count) numbers stored")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                NavigationLink(destination: SessionDetailView(session: session)) {
                                    VStack(alignment: .leading) {
                                        Text(session.name)
                                            .font(.headline)
                                        HStack {
                                            Text("\(session.numbers.count) numbers")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if !session.collectedNumbers.isEmpty {
                                                Text("• \(session.collectedNumbers.count) collected")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                            }
                                            if !session.missingNumbers.isEmpty {
                                                Text("• \(session.missingNumbers.count) missing")
                                                    .font(.caption)
                                                    .foregroundColor(.red)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }

                Spacer()

                Button(action: showStartOptions) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Start Session")
                    }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(15)
                }
                .padding()
            }
            .navigationTitle("Scalete")
            .navigationBarItems(trailing: HStack {
                if isEditing {
                    Button("Delete") {
                        savedSessions.removeAll { selectedSessions.contains($0.id) }
                        selectedSessions.removeAll()
                        isEditing = false
                        saveSessions() // Save after deletion
                    }
                    .foregroundColor(.red)
                    
                    Button("Select All") {
                        selectedSessions = Set(savedSessions.map { $0.id })
                    }
                }
                Button(isEditing ? "Cancel" : "Select") {
                    isEditing.toggle()
                    if !isEditing {
                        selectedSessions.removeAll()
                    }
                }
            })
            .photosPicker(isPresented: $showPhotoPicker, selection: $imageSelections, maxSelectionCount: 10, matching: .images)
            .onChange(of: imageSelections) { _, newItems in
                for item in newItems {
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            recognizeText(from: uiImage)
                        }
                    }
                }
                imageSelections.removeAll()
                if !newItems.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        showingAddMorePrompt = true
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraView(imageHandler: { image in
                    if let image = image {
                        recognizeText(from: image)
                        showingAddMorePrompt = true
                    }
                })
            }
            .fullScreenCover(isPresented: $showManualInput) {
                ManualRackInputView(
                    isPresented: $showManualInput,
                    extractedNumbers: $extractedNumbers,
                    onComplete: { shouldStartScanning in
                        if shouldStartScanning {
                            // User chose "Start Search"
                            saveSession()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                showLiveScanner = true
                            }
                        } else {
                            // User chose "Store Values as List"
                            saveSession()
                        }
                    }
                )
            }
            .fullScreenCover(isPresented: $showLiveScanner) {
                if let session = currentSession {
                    LiveScannerView(session: .constant(session), onComplete: { updatedSession in
                        if let index = savedSessions.firstIndex(where: { $0.id == updatedSession.id }) {
                            savedSessions[index] = updatedSession
                            saveSessions() // Save after updating session
                        }
                        currentSession = nil
                        showLiveScanner = false
                    })
                }
            }
            .alert("Add More Racks?", isPresented: $showingAddMorePrompt) {
                Button("Add more Racks to my Search") {
                    showCamera = true
                }
                Button("Finished", role: .cancel) {
                    promptToScan()
                }
            } message: {
                Text("Found \(extractedNumbers.count) numbers. Would you like to add more?")
            }
        }
    }

    func showStartOptions() {
        let alert = UIAlertController(title: "Start Session", message: "Choose how to begin", preferredStyle: .actionSheet)
        
        // Updated option - replaced "Scan Initial Values" with "Manually Type in Rack"
        alert.addAction(UIAlertAction(title: "Manually Type in Rack", style: .default) { _ in
            showManualInput = true
        })
        
        alert.addAction(UIAlertAction(title: "Choose from Album", style: .default) { _ in
            showPhotoPicker = true
        })
        
        alert.addAction(UIAlertAction(title: "Use Camera", style: .default) { _ in
            showCamera = true
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        // Handle iPad popover presentation
        if let popover = alert.popoverPresentationController {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                popover.sourceView = window.rootViewController?.view
                popover.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height - 100, width: 0, height: 0)
            }
        }
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }

    func promptToScan() {
        let alert = UIAlertController(title: "Start Scanning?", message: "Would you like to start scanning now or just store the values?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Start Scanning", style: .default) { _ in
            saveSession()
            showLiveScanner = true
        })
        alert.addAction(UIAlertAction(title: "Just Store Values", style: .cancel) { _ in
            saveSession()
        })
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }

    func recognizeText(from image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let regex = try! NSRegularExpression(pattern: "\\b\\d{4,6}\\b") // Changed to 4-6 digits
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let newNumbers = matches.map { String(text[Range($0.range, in: text)!]) }
            DispatchQueue.main.async {
                extractedNumbers.formUnion(newNumbers)
            }
        }
        request.recognitionLevel = .accurate
        try? handler.perform([request])
    }

    func saveSession() {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a MM/dd/yy"
        let timestamp = formatter.string(from: Date())
        let session = Session(name: "Session - \(timestamp)", numbers: Array(extractedNumbers).sorted())
        savedSessions.append(session)
        currentSession = session
        extractedNumbers.removeAll()
        saveSessions() // Persist to UserDefaults
    }

    func deleteSessions(at offsets: IndexSet) {
        savedSessions.remove(atOffsets: offsets)
        saveSessions() // Persist to UserDefaults
    }
}
