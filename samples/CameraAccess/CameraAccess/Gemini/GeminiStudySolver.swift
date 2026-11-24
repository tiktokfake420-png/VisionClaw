import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class GeminiStudySolver: NSObject, ObservableObject {
    @Published var isSolving: Bool = false
    @Published var lastAnswer: String = ""
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()

    func solveStudyImage(_ image: UIImage, apiKey: String) async {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanKey.isEmpty else {
            let msg = "Нажми на иконку ключа и вставь свой Gemini API Key."
            errorMessage = msg
            lastAnswer = msg
            speak(msg)
            return
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.75) else {
            let msg = "Не удалось подготовить кадр с камеры."
            errorMessage = msg
            lastAnswer = msg
            speak(msg)
            return
        }

        isSolving = true
        errorMessage = nil
        lastAnswer = "Анализирую кадр через Gemini..."

        let base64Image = jpegData.base64EncodedString()
        let prompt = """
        Ты голосовой помощник для учёбы. На изображении показан учебный пример, задача или текст.
        Дай краткое пошаговое решение, понятное на слух (без длинных формул, LaTeX-символов и лишних вводных фраз), и в конце чётко назови итоговый ответ.
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
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

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            isSolving = false
            let msg = "Ошибка формирования запроса."
            errorMessage = msg
            lastAnswer = msg
            return
        }

        // Для ключей формата AQ.... пробуем сначала Vertex AI Express, затем стандартный Gemini API
        let endpoints: [String] = cleanKey.hasPrefix("AQ.")
            ? [
                "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:generateContent",
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
            ]
            : [
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
                "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:generateContent"
            ]

        var lastErrorMsg = "Не удалось получить ответ от Gemini."

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cleanKey, forHTTPHeaderField: "x-goog-api-key")
            request.timeoutInterval = 30
            request.httpBody = bodyData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    let bodyText = String(data: data, encoding: .utf8) ?? "Ошибка сервера"
                    lastErrorMsg = "Ошибка Gemini (\(httpResponse.statusCode)): \(bodyText)"
                    continue
                }

                if
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let candidates = json["candidates"] as? [[String: Any]],
                    let firstCandidate = candidates.first,
                    let content = firstCandidate["content"] as? [String: Any],
                    let parts = content["parts"] as? [[String: Any]]
                {
                    let rawText = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
                    let answer = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !answer.isEmpty {
                        lastAnswer = answer
                        isSolving = false
                        speak(answer)
                        return
                    }
                }
            } catch {
                lastErrorMsg = "Ошибка сети: \(error.localizedDescription)"
            }
        }

        isSolving = false
        errorMessage = lastErrorMsg
        lastAnswer = lastErrorMsg
        speak("Не удалось получить ответ от Gemini. Проверь текст ошибки на экране.")
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try? session.setActive(true)

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
}
