import SwiftUI
import AVFoundation
import CoreHaptics

struct LiveCameraView: UIViewRepresentable {
    let numbersToMatch: Set<String>
    @Binding var collectedNumbers: Set<String>
    @Binding var isScanning: Bool
    @Binding var hapticEngine: CHHapticEngine?
    @Binding var debugText: String
    
    func makeUIView(context: Context) -> LiveCameraUIView {
        let view = LiveCameraUIView()
        view.numbersToMatch = numbersToMatch
        view.collectedNumbers = collectedNumbers
        view.hapticEngine = hapticEngine
        view.onNumberCollected = { number in
            collectedNumbers.insert(number)
        }
        view.onDebugUpdate = { text in
            debugText = text
        }
        return view
    }
    
    func updateUIView(_ uiView: LiveCameraUIView, context: Context) {
        uiView.numbersToMatch = numbersToMatch
        uiView.isScanning = isScanning
        uiView.collectedNumbers = collectedNumbers // Update collected numbers
    }
}
