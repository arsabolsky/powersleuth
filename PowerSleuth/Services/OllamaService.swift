import Foundation

struct OllamaModel: Identifiable, Hashable, Sendable {
    let name: String
    let sizeBytes: Int64

    var id: String { name }

    var sizeLabel: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        return gb < 1
            ? String(format: "%.0f MB", gb * 1024)
            : String(format: "%.1f GB", gb)
    }

    var shortName: String { name.components(separatedBy: ":").first ?? name }
}

@MainActor
final class OllamaService: ObservableObject {
    static let shared = OllamaService()
    private init() {}

    @Published var isDetected = false
    @Published var models: [OllamaModel] = []
    @Published var isChecking = false

    private let baseURL = "http://localhost:11434"

    func check() async {
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "\(baseURL)/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            struct TagsResponse: Decodable {
                struct ModelInfo: Decodable { let name: String; let size: Int64? }
                let models: [ModelInfo]
            }

            let response = try JSONDecoder().decode(TagsResponse.self, from: data)
            isDetected = true
            models = response.models
                .map { OllamaModel(name: $0.name, sizeBytes: $0.size ?? 0) }
                .sorted { $0.name < $1.name }
        } catch {
            isDetected = false
            models = []
        }
    }

    func generate(model: String, prompt: String) async throws -> String {
        struct GenerateRequest: Encodable {
            let model: String; let prompt: String; let stream: Bool
        }
        struct GenerateResponse: Decodable { let response: String }

        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GenerateRequest(model: model, prompt: prompt, stream: false)
        )
        request.timeoutInterval = 180

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GenerateResponse.self, from: data).response
    }
}
