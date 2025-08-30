import Foundation

struct Session: Identifiable, Equatable, Codable {
    let id = UUID()
    var name: String  // Changed from 'let' to 'var'
    var numbers: [String]  // Changed from 'let' to 'var'
    var collectedNumbers: [String] = []
    var missingNumbers: [String] = []
}
