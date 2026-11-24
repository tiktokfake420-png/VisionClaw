/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//

import AVFoundation
import Combine
import CoreImage
import Foundation
import MWDATCore
import SwiftUI
import UIKit

@MainActor
final class GeminiStudySolver: NSObject, ObservableObject {
    @Published var isSolving: Bool = false
    @Published var lastAnswer: String = ""
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()

    func solveStudyImage(_ image: UIImage, apiKey: String, customBaseURL: String, customModel: String) async {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanKey.isEmpty else {
            let msg = "Нажми на иконку ключа и вставь свой API Key."
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
        lastAnswer = "Анализирую кадр..."

        let base64Image = jpegData.base64EncodedString()
        let prompt = """
        Ты голосовой помощник для учёбы. На изображении показан учебный пример, задача или текст.
        Дай краткое пошаговое решение, понятное на слух (без длинных формул, LaTeX-символов и лишних вводных фраз), и в конце чётко назови итоговый ответ.
        """

        // 1. OpenAI-совместимый шлюз (для ключей sk-..., например triklz27.ru)
        if cleanKey.hasPrefix("sk-") {
            let base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "https://triklz27.ru/v1"
                : customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let modelName = customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "hy4"
                : customModel.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let url = URL(string: "\(base)/chat/completions") else {
                isSolving = false
                let msg = "Некорректный Base URL: \(base)"
                errorMessage = msg
                lastAnswer = msg
                return
            }

            let openAIPayload: [String: Any] = [
                "model": modelName,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "text", "text": prompt],
                            [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:image/jpeg;base64,\(base64Image)"
                                ]
                            ]
                        ]
                    ]
                ],
                "max_tokens": 800
            ]

            guard let bodyData = try? JSONSerialization.data(withJSONObject: openAIPayload) else {
                isSolving = false
                let msg = "Ошибка формирования запроса."
                errorMessage = msg
                lastAnswer = msg
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 35
            request.httpBody = bodyData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    let bodyText = String(data: data, encoding: .utf8) ?? "Ошибка сервера"
                    isSolving = false
                    let msg = "Ошибка API (\(httpResponse.statusCode)): \(bodyText)"
                    errorMessage = msg
                    lastAnswer = msg
                    speak("Ошибка запроса. Код \(httpResponse.statusCode).")
                    return
                }

                if
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]],
                    let firstChoice = choices.first,
                    let message = firstChoice["message"] as? [String: Any],
                    let content = message["content"] as? String
                {
                    let answer = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !answer.isEmpty {
                        lastAnswer = answer
                        isSolving = false
                        speak(answer)
                        return
                    }
                }

                isSolving = false
                let msg = "Не удалось прочитать ответ от сервера."
                errorMessage = msg
                lastAnswer = msg
                speak(msg)
            } catch {
                isSolving = false
                let msg = "Ошибка сети: \(error.localizedDescription)"
                errorMessage = msg
                lastAnswer = msg
                speak("Ошибка сети.")
            }
            return
        }

        // 2. Прямой Google Gemini API (для ключей AQ.... и AIza...)
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

        let models = [
            "gemini-4-hydrogen",
            "gemini-3.8-flash",
            "gemini-4-carbon"
        ]

        var endpoints: [String] = []
        for model in models {
            if cleanKey.hasPrefix("AQ.") {
                endpoints.append("https://aiplatform.googleapis.com/v1/publishers/google/models/\(model):generateContent")
                endpoints.append("https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
            } else {
                endpoints.append("https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
                endpoints.append("https://aiplatform.googleapis.com/v1/publishers/google/models/\(model):generateContent")
            }
        }

        var lastErrorMsg = "Не удалось получить ответ от Gemini."

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cleanKey
