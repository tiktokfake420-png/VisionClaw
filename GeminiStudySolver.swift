import Foundation
import AVFoundation
import UIKit
import Combine

@MainActor
final class GeminiStudySolver: NSObject, ObservableObject {
    @Published var isSolving: Bool = false
    @Published var lastAnswer: String = ""
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()

    func solveStudyImage(_ image: UIImage, apiKey: String) async {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            errorMessage = "Укажи Gemini API Key."
            return
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.75) else {
            errorMessage = "Не удалось подготовить изображение."
            return
        }

        isSolving = true
        errorMessage = nil
        lastAnswer = "Решаю задачу..."

        let base64Image = jpegData.base64EncodedString()
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(cleanKey)"

        guard let url = URL(string: endpoint) else {
            isSolving = false
            errorMessage = "Некорректный адрес API."
            return
        }

        let prompt = """
        Ты голосовой помощник для учёбы. На изображении показан учебный пример или задача.
        Дай краткое пошаговое решение, понятное на слух (без длинных формул, LaTeX-символов и лишних вводных фраз), и в конце чётко назови итоговый ответ.
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? "Ошибка сервера"
                isSolving = false
                errorMessage = "HTTP \(httpResponse.statusCode): \(bodyText)"
                return
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = json["candidates"] as? [[String: Any]],
                let firstCandidate = candidates.first,
                let content = firstCandidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let answer = parts.compactMap({ $0["text"] as? String }).joined(separator: " ").nilIfEmpty
            else {
                isSolving = false
                errorMessage = "Не удалось прочитать ответ модели."
                return
            }

            lastAnswer = answer
            isSolving = false
            speak(answer)
        } catch {
            isSolving = false
            errorMessage = "Ошибка сети: \(error.localizedDescription)"
        }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
