import Foundation

struct FeedbackService {
    private struct Submission: Encodable {
        let message: String
        let source: String
        let appVersion: String
    }

    private struct ServerResponse: Decodable {
        let error: String?
    }

    func submit(_ message: String) async throws {
        guard let rawEndpoint = Bundle.main.object(forInfoDictionaryKey: "FeedbackAPIURL") as? String,
              let endpoint = URL(string: rawEndpoint),
              endpoint.scheme == "https" else {
            throw FeedbackError.unavailable
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Submission(message: message, source: "BandLoop iOS", appVersion: version)
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FeedbackError.failed
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let serverMessage = try? JSONDecoder().decode(ServerResponse.self, from: data).error
                throw FeedbackError.server(serverMessage ?? "잠시 후 다시 시도해 주세요.")
            }
        } catch let error as FeedbackError {
            throw error
        } catch {
            throw FeedbackError.network
        }
    }
}

enum FeedbackError: LocalizedError {
    case unavailable
    case network
    case failed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "의견 접수 연결을 준비하고 있어요."
        case .network:
            return "인터넷 연결을 확인하고 다시 시도해 주세요."
        case .failed:
            return "의견을 보내지 못했어요. 잠시 후 다시 시도해 주세요."
        case let .server(message):
            return message
        }
    }
}
