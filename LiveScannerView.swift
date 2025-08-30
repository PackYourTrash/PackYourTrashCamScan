import SwiftUI
import Vision
import AVFoundation
import CoreHaptics

struct LiveScannerView: View {
    @Binding var session: Session
    let onComplete: (Session) -> Void
    @State private var isScanning = true
    @State private var showConfirmRacks = false
    @State private var collectedNumbers: Set<String> = []
    @State private var confirmedNumbers: Set<String> = []
    @State private var missingNumbers: Set<String> = []
    @State private var showMissingAlert = false
    @State private var scanningForMissing = false
    @State private var showCamera = false
    @State private var hapticEngine: CHHapticEngine?
    @State private var debugText = "Initializing..."
    @State private var scannedRackNumbers: Set<String> = []
    @State private var showConfirmationView = false
    @State private var confirmationImages: [UIImage] = []
    @State private var showAddMoreImagesPrompt = false
    @State private var isInitialScan: Bool = false
    
    private var numbersToScan: Set<String> {
        if scanningForMissing {
            return missingNumbers
        } else {
            return Set(session.numbers)
        }
    }
    
    var body: some View {
        if showConfirmationView {
            // Confirmation view after scanning racks
            VStack(spacing: 20) {
                Text("Rack Confirmation")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top, 40)
                
                VStack(alignment: .leading, spacing: 15) {
                    Text("Original List (\(session.numbers.count) items)")
                        .font(.headline)
                    ScrollView {
                        Text(session.numbers.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(maxHeight: 150)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    
                    Text("Scanned from Racks (\(scannedRackNumbers.count) items)")
                        .font(.headline)
                    ScrollView {
                        Text(scannedRackNumbers.sorted().joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(maxHeight: 150)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(10)
                    
                    if !missingNumbers.isEmpty {
                        Text("Missing Items (\(missingNumbers.count))")
                            .font(.headline)
                            .foregroundColor(.red)
                        ScrollView {
                            Text(missingNumbers.sorted().joined(separator: ", "))
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(maxHeight: 100)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(10)
                    }
                }
                .padding()
                
                Spacer()
                
                VStack(spacing: 15) {
                    if !missingNumbers.isEmpty {
                        Button(action: continueScanningMissing) {
                            HStack {
                                Image(systemName: "magnifyingglass.circle.fill")
                                Text("Continue Scanning for Missing Items")
                            }
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(15)
                        }
                    }
                    
                    Button(action: cancelAndGoHome) {
                        HStack {
                            Image(systemName: "house.circle.fill")
                            Text("Go Back to Home")
                        }
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                }
                .padding()
            }
        } else {
            // Main scanning view
            ZStack {
                // Camera view - pass empty set for initial scan
                LiveCameraView(
                    numbersToMatch: isInitialScan ? Set<String>() : numbersToScan,
                    collectedNumbers: $collectedNumbers,
                    isScanning: $isScanning,
                    hapticEngine: $hapticEngine,
                    debugText: $debugText
                )
                .edgesIgnoringSafeArea(.all)
                
                VStack {
                    // Top bar
                    HStack {
                        Button(action: {
                            // If in initial scan mode and we have collected numbers, save them first
                            if isInitialScan && !collectedNumbers.isEmpty {
                                saveInitialScanAndExit()
                            } else {
                                onComplete(session)
                            }
                        }) {
                            Text("Cancel")
                                .padding()
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing) {
                            if isInitialScan {
                                Text("Initial Capture")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                Text("\(collectedNumbers.count) numbers found")
                                    .font(.subheadline)
                            } else {
                                Text(scanningForMissing ? "Scanning Missing" : "Scanning")
                                    .font(.headline)
                                Text("\(collectedNumbers.count) / \(numbersToScan.count)")
                                    .font(.subheadline)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .padding()
                    
                    // Show collected numbers in initial scan mode
                    if isInitialScan && !collectedNumbers.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Collected Numbers:")
                                .font(.caption.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(collectedNumbers.sorted(), id: \.self) { number in
                                        Text(number)
                                            .font(.system(.caption, design: .monospaced))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.green.opacity(0.8))
                                            .foregroundColor(.white)
                                            .cornerRadius(5)
                                    }
                                }
                            }
                            .frame(maxHeight: 30)
                        }
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                    
                    // Bottom controls
                    VStack(spacing: 15) {
                        // Add save button for initial scan mode
                        if isInitialScan && !collectedNumbers.isEmpty {
                            VStack(spacing: 10) {
                                Button(action: saveInitialScan) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Save \(collectedNumbers.count) Numbers & Start Scanning")
                                    }
                                    .font(.headline)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(15)
                                }
                                
                                Button(action: clearCollectedNumbers) {
                                    HStack {
                                        Image(systemName: "trash.circle")
                                        Text("Clear All")
                                    }
                                    .font(.subheadline)
                                    .padding(10)
                                    .background(Color.orange.opacity(0.8))
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                            }
                        }
                        
                        // Only show Confirm Racks if we have numbers to match and have collected some
                        if !collectedNumbers.isEmpty && !isInitialScan && !numbersToScan.isEmpty {
                            Button(action: confirmRacks) {
                                HStack {
                                    Image(systemName: "checkmark.rectangle.stack")
                                    Text("Confirm Racks")
                                }
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(15)
                            }
                        }
                        
                        Button(action: endSession) {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                Text(isInitialScan && !collectedNumbers.isEmpty ? "Save & Exit" : "End Session")
                            }
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(15)
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.8))
                }
                
                // Instructions overlay for initial scan
                if isInitialScan && collectedNumbers.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "viewfinder.circle")
                                .font(.system(size: 50))
                                .foregroundColor(.green)
                            Text("Move camera across the page")
                                .font(.headline)
                            Text("Numbers will be highlighted in green and collected automatically")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(15)
                        .padding()
                        Spacer()
                        Spacer()
                    }
                }
            }
            .onAppear {
                prepareHaptics()
                // Check if this is initial scan mode
                isInitialScan = session.numbers.isEmpty
                
                // Debug: Print what numbers we're looking for
                if !isInitialScan {
                    print("DEBUG: Looking for numbers: \(session.numbers)")
                    print("DEBUG: Numbers to scan: \(numbersToScan)")
                    debugText = "Looking for \(numbersToScan.count) numbers: \(Array(numbersToScan).sorted().joined(separator: ", "))"
                } else {
                    debugText = "Move camera to scan numbers"
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraView { image in
                    if let image = image {
                        confirmationImages.append(image)
                        showAddMoreImagesPrompt = true
                    }
                }
            }
            .alert("Add More Pictures?", isPresented: $showAddMoreImagesPrompt) {
                Button("Take Another Picture") {
                    showCamera = true
                }
                Button("Done - Process Images", role: .cancel) {
                    processConfirmationImages()
                }
            } message: {
                Text("You've taken \(confirmationImages.count) picture(s). Would you like to add more?")
            }
        }
    }
    
    func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            print("Haptic engine error: \(error)")
        }
    }
    
    func clearCollectedNumbers() {
        collectedNumbers.removeAll()
        debugText = "Cleared all numbers. Start scanning again."
    }
    
    func saveInitialScan() {
        // Update session with collected numbers
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a MM/dd/yy"
        let timestamp = formatter.string(from: Date())
        
        session.name = "Session - \(timestamp)"
        session.numbers = Array(collectedNumbers).sorted()
        
        // Reset for normal scanning mode
        isInitialScan = false
        collectedNumbers.removeAll()
        isScanning = true
        debugText = "Now scan the racks to find these \(session.numbers.count) numbers"
    }
    
    func saveInitialScanAndExit() {
        // Save and exit
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a MM/dd/yy"
        let timestamp = formatter.string(from: Date())
        
        session.name = "Session - \(timestamp)"
        session.numbers = Array(collectedNumbers).sorted()
        onComplete(session)
    }
    
    func confirmRacks() {
        isScanning = false
        confirmationImages.removeAll() // Clear any previous images
        showCamera = true
    }
    
    func processConfirmationImages() {
        // Process all collected images
        scannedRackNumbers.removeAll()
        
        for image in confirmationImages {
            recognizeTextForConfirmation(from: image)
        }
        
        // Clear images after processing
        confirmationImages.removeAll()
    }
    
    func recognizeTextForConfirmation(from image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            for observation in observations {
                guard let topCandidate = observation.topCandidates(1).first else { continue }
                let text = topCandidate.string
                
                // Check for date patterns
                let dateRegex = try! NSRegularExpression(pattern: "\\d{1,2}/\\d{1,2}/\\d{4}")
                let fullText = text.replacingOccurrences(of: " ", with: "")
                let hasDatePattern = dateRegex.firstMatch(in: fullText, range: NSRange(fullText.startIndex..., in: fullText)) != nil
                
                // Extract numbers
                let regex = try! NSRegularExpression(pattern: "\\b\\d{4,6}\\b")
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                
                for match in matches {
                    let number = String(text[Range(match.range, in: text)!])
                    
                    // Skip 4-digit years
                    if number.count == 4 {
                        if let intValue = Int(number), intValue >= 1900 && intValue <= 2099 {
                            if hasDatePattern || text.contains("/") {
                                continue
                            }
                        }
                    }
                    
                    self.scannedRackNumbers.insert(number)
                }
            }
            
            DispatchQueue.main.async {
                // After processing all images, calculate missing
                if self.confirmationImages.isEmpty {
                    // Calculate missing numbers
                    self.missingNumbers = Set(self.session.numbers).subtracting(self.scannedRackNumbers)
                    
                    // Show confirmation view
                    self.showConfirmationView = true
                }
            }
        }
        request.recognitionLevel = .accurate
        try? handler.perform([request])
    }
    
    func continueScanningMissing() {
        // Set up for scanning only missing items
        scanningForMissing = true
        collectedNumbers = Set<String>() // Clear collected numbers
        showConfirmationView = false
        isScanning = true
        
        // Update session with current state
        session.collectedNumbers = Array(scannedRackNumbers)
        session.missingNumbers = Array(missingNumbers)
    }
    
    func cancelAndGoHome() {
        // Update session with results before going home
        session.collectedNumbers = Array(scannedRackNumbers)
        session.missingNumbers = Array(missingNumbers)
        onComplete(session)
    }
    
    func endSession() {
        if isInitialScan {
            // For initial scan, save collected numbers as the session numbers
            session.numbers = Array(collectedNumbers).sorted()
            let formatter = DateFormatter()
            formatter.dateFormat = "hh:mm a MM/dd/yy"
            let timestamp = formatter.string(from: Date())
            session.name = "Session - \(timestamp)"
        } else if scanningForMissing {
            // If we were scanning for missing, update the collected numbers
            session.collectedNumbers = Array(scannedRackNumbers.union(collectedNumbers))
            session.missingNumbers = Array(missingNumbers.subtracting(collectedNumbers))
        } else if !scannedRackNumbers.isEmpty {
            // If we have scanned rack numbers, use those
            session.collectedNumbers = Array(scannedRackNumbers)
            session.missingNumbers = Array(missingNumbers)
        } else {
            // Otherwise use the live collected numbers
            session.collectedNumbers = Array(collectedNumbers)
            // Calculate missing numbers
            let missing = Set(session.numbers).subtracting(collectedNumbers)
            session.missingNumbers = Array(missing)
        }
        onComplete(session)
    }
}
