import SwiftUI
import AVFoundation

struct ManualRackInputView: View {
    @Binding var isPresented: Bool
    @Binding var extractedNumbers: Set<String>
    let onComplete: (Bool) -> Void  // Single callback with Bool parameter
    
    @State private var currentInput: String = ""
    @State private var storedValues: [String] = []
    @State private var editingIndex: Int? = nil
    @State private var showingInvalidAlert = false
    @State private var invalidMessage = ""
    @State private var isEditMode: Bool = false
    @State private var showingFinishOptions = false
    
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    private let successFeedback = UINotificationFeedbackGenerator()
    
    var body: some View {
        ZStack {
            // Background with blur effect
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    // Dismiss keyboard if editing
                    editingIndex = nil
                }
            
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 10) {
                    HStack {
                        Button(action: {
                            isPresented = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        Spacer()
                        
                        Text("Manual Rack Input")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        // Placeholder for balance
                        Color.clear
                            .frame(width: 30, height: 30)
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                    
                    // Current input display
                    VStack(spacing: 5) {
                        if isEditMode, let index = editingIndex {
                            Text("Editing #\(index + 1)")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                        Text(currentInput.isEmpty ? "Enter rack number" : currentInput)
                            .font(.system(size: 32, weight: .medium, design: .monospaced))
                            .foregroundColor(currentInput.isEmpty ? .white.opacity(0.5) : .white)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                            .background(
                                RoundedRectangle(cornerRadius: 15)
                                    .fill(isEditMode ? Color.yellow.opacity(0.15) : Color.white.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 15)
                                            .stroke(isEditMode ? Color.yellow.opacity(0.5) : Color.clear, lineWidth: 2)
                                    )
                            )
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
                .background(
                    VisualEffectBlur(blurStyle: .systemUltraThinMaterialDark)
                )
                
                // Stored values list
                if !storedValues.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(storedValues.enumerated()), id: \.offset) { index, value in
                                HStack {
                                    Text("#\(index + 1)")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.5))
                                        .frame(width: 30)
                                    
                                    Text(value)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            startEditing(at: index)
                                        }
                                    
                                    Spacer()
                                    
                                    // Delete button - larger rectangular style
                                    Button(action: {
                                        withAnimation(.spring()) {
                                            deleteValue(at: index)
                                        }
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "trash.fill")
                                                .font(.system(size: 16))
                                            Text("Delete")
                                                .font(.system(size: 14, weight: .medium))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.red.opacity(0.7))
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill((isEditMode && editingIndex == index) ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke((isEditMode && editingIndex == index) ? Color.yellow.opacity(0.5) : Color.clear, lineWidth: 2)
                                        )
                                )
                            }
                        }
                        .padding()
                    }
                    .background(
                        VisualEffectBlur(blurStyle: .systemUltraThinMaterialDark)
                    )
                } else {
                    // Empty state
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.3))
                        Text("No values added yet")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .frame(maxHeight: 100)
                    .frame(maxWidth: .infinity)
                    .background(
                        VisualEffectBlur(blurStyle: .systemUltraThinMaterialDark)
                    )
                }
                
                Spacer()
                
                // Number pad
                VStack(spacing: 12) {
                    // Number buttons grid
                    ForEach(0..<3) { row in
                        HStack(spacing: 12) {
                            ForEach(1...3, id: \.self) { col in
                                let number = row * 3 + col
                                NumberButton(number: "\(number)") {
                                    appendNumber("\(number)")
                                }
                            }
                        }
                    }
                    
                    // Bottom row: Clear, 0, Backspace
                    HStack(spacing: 12) {
                        // Clear button
                        Button(action: {
                            currentInput = ""
                            hapticFeedback.impactOccurred()
                        }) {
                            Text("Clear")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 100, height: 65)
                                .background(
                                    RoundedRectangle(cornerRadius: 15)
                                        .fill(Color.orange.opacity(0.3))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 15)
                                                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                        )
                                )
                        }
                        
                        NumberButton(number: "0") {
                            appendNumber("0")
                        }
                        
                        // Backspace button
                        Button(action: {
                            if !currentInput.isEmpty {
                                currentInput.removeLast()
                                hapticFeedback.impactOccurred()
                            }
                        }) {
                            Image(systemName: "delete.left.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 100, height: 65)
                                .background(
                                    RoundedRectangle(cornerRadius: 15)
                                        .fill(Color.white.opacity(0.15))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 15)
                                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                        }
                    }
                }
                .padding()
                .background(
                    VisualEffectBlur(blurStyle: .systemUltraThinMaterialDark)
                )
                
                // Bottom action buttons
                HStack(spacing: 20) {
                    // Blue checkmark button (add to list or save edit)
                    Button(action: isEditMode ? saveEdit : addToList) {
                        Image(systemName: isEditMode ? "checkmark.square.fill" : "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(isEditMode ? .yellow : .blue)
                            .background(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 45, height: 45)
                            )
                    }
                    .disabled(currentInput.isEmpty)
                    .opacity(currentInput.isEmpty ? 0.5 : 1.0)
                    
                    Spacer()
                    
                    // Cancel edit button (only shown in edit mode)
                    if isEditMode {
                        Button(action: cancelEdit) {
                            Text("Cancel Edit")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 15)
                                        .fill(Color.orange.opacity(0.8))
                                )
                        }
                    } else if !storedValues.isEmpty {
                        // Counter badge
                        VStack(spacing: 4) {
                            Text("\(storedValues.count)")
                                .font(.title.bold())
                                .foregroundColor(.white)
                            Text("Values Added")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    
                    Spacer()
                    
                    // Green finished button
                    Button(action: {
                        if !storedValues.isEmpty && !isEditMode {
                            showingFinishOptions = true
                        }
                    }) {
                        Text("Finished")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 120, height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 25)
                                    .fill(Color.green)
                            )
                    }
                    .disabled(storedValues.isEmpty || isEditMode)
                    .opacity((storedValues.isEmpty || isEditMode) ? 0.5 : 1.0)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
                .background(
                    VisualEffectBlur(blurStyle: .systemUltraThinMaterialDark)
                )
            }
        }
        .confirmationDialog("What would you like to do?", isPresented: $showingFinishOptions, titleVisibility: .visible) {
            Button("Start Search") {
                // Convert stored values to Set
                extractedNumbers = Set(storedValues)
                successFeedback.notificationOccurred(.success)
                // Close view and start search
                isPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onComplete(true)  // true = start scanning
                }
            }
            Button("Store Values as List") {
                // Convert stored values to Set
                extractedNumbers = Set(storedValues)
                successFeedback.notificationOccurred(.success)
                // Close view and just store
                isPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onComplete(false)  // false = just store
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You have added \(storedValues.count) rack numbers")
        }
        .alert("Invalid Input", isPresented: $showingInvalidAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(invalidMessage)
        }
    }
    
    private func startEditing(at index: Int) {
        isEditMode = true
        editingIndex = index
        currentInput = storedValues[index]
        hapticFeedback.impactOccurred()
    }
    
    private func saveEdit() {
        guard let index = editingIndex else { return }
        
        // Validate the edited value
        if currentInput.count < 4 {
            invalidMessage = "Rack number must be at least 4 digits"
            showingInvalidAlert = true
            return
        }
        
        if currentInput.count > 6 {
            invalidMessage = "Rack number must be at most 6 digits"
            showingInvalidAlert = true
            return
        }
        
        // Check for duplicates (excluding the current item being edited)
        var tempValues = storedValues
        tempValues.remove(at: index)
        if tempValues.contains(currentInput) {
            invalidMessage = "This rack number has already been added"
            showingInvalidAlert = true
            return
        }
        
        // Save the edited value
        withAnimation(.spring()) {
            storedValues[index] = currentInput
            successFeedback.notificationOccurred(.success)
        }
        
        // Reset edit mode
        cancelEdit()
    }
    
    private func cancelEdit() {
        isEditMode = false
        editingIndex = nil
        currentInput = ""
        hapticFeedback.impactOccurred()
    }
    
    private func deleteValue(at index: Int) {
        // If we're editing this item, cancel the edit
        if editingIndex == index {
            cancelEdit()
        }
        storedValues.remove(at: index)
        hapticFeedback.impactOccurred()
    }
    
    private func appendNumber(_ number: String) {
        hapticFeedback.impactOccurred()
        
        // Limit to 6 digits
        if currentInput.count < 6 {
            currentInput.append(number)
        }
    }
    
    private func addToList() {
        guard !currentInput.isEmpty else { return }
        
        // Validate 4-6 digits
        if currentInput.count < 4 {
            invalidMessage = "Rack number must be at least 4 digits"
            showingInvalidAlert = true
            return
        }
        
        // Check for duplicates
        if storedValues.contains(currentInput) {
            invalidMessage = "This rack number has already been added"
            showingInvalidAlert = true
            return
        }
        
        // Add to list with animation
        withAnimation(.spring()) {
            storedValues.append(currentInput)
            successFeedback.notificationOccurred(.success)
        }
        
        // Clear input for next entry
        currentInput = ""
    }
}

// Custom number button component
struct NumberButton: View {
    let number: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 100, height: 65)
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color.white.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                )
        }
    }
}

// Visual effect blur view for iOS
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
    }
}
