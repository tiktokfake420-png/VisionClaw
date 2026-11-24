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
        let prompt = "Ты голосовой помощник для учёбы. На изображении показан учебный пример, задача или текст. Дай краткое пошаговое решение, понятное на слух, без длинных формул и LaTeX-символов, и в конце чётко назови итоговый ответ."

        if cleanKey.hasPrefix("sk-") {
            await solveWithOpenAICompatible(
                base64Image: base64Image,
                prompt: prompt,
                apiKey: cleanKey,
                customBaseURL: customBaseURL,
                customModel: customModel
            )
        } else {
            await solveWithGoogleNative(
                base64Image: base64Image,
                prompt: prompt,
                apiKey: cleanKey
            )
        }
    }

    private func solveWithOpenAICompatible(
        base64Image: String,
        prompt: String,
        apiKey: String,
        customBaseURL: String,
        customModel: String
    ) async {
        let rawBase = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = rawBase.isEmpty
            ? "https://triklz27.ru/v1"
            : rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let rawModel = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = rawModel.isEmpty ? "hy4" : rawModel

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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    }

    private func solveWithGoogleNative(base64Image: String, prompt: String, apiKey: String) async {
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

        let models = ["gemini-4-hydrogen", "gemini-3.8-flash", "gemini-4-carbon"]
        var endpoints: [String] = []
        for model in models {
            if apiKey.hasPrefix("AQ.") {
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
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
        speak("Не удалось получить ответ. Проверь текст ошибки на экране.")
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

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var liveKit = LiveKitSession()
  @StateObject private var studySolver = GeminiStudySolver()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.openai.rawValue
  @AppStorage(SettingsManager.assistiveModeKey) private var assistiveMode = false
  @AppStorage("custom_gemini_api_key") private var savedApiKey: String = ""
  @AppStorage("custom_api_base_url") private var savedBaseURL: String = "https://triklz27.ru/v1"
  @AppStorage("custom_api_model") private var savedModel: String = "hy4"
  @State private var showKeyPrompt = false
  @State private var tempApiKey: String = ""
  @State private var tempBaseURL: String = ""
  @State private var tempModel: String = ""
  @State private var glassesAutoStarted = false
  @State private var latestGlassesImage: UIImage?
  private let ciContext = CIContext()

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  private var glassesPlaceholder: (title: String, caption: String) {
    switch viewModel.glassesIssue {
    case .sdkUnavailable:
      return ("Glasses unavailable", "The glasses SDK is not available on this device.")
    case .permissionNeeded:
      return ("Glasses permission needed", "Allow it in the Meta AI app.")
    case .hingesClosed:
      return ("Glasses folded", "Open the hinges to start streaming.")
    case .reconnecting:
      return ("Reconnecting to glasses", "Make sure your glasses are on and the hinges are open.")
    case nil:
      return ("Put on your glasses",
              "Open the hinges and put them on. The camera turns off when they're folded or off your face.")
    }
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  @ViewBuilder
  private var mainStreamLayer: some View {
    if captureSource == .iPhoneCamera {
      LiveKitStreamView(session: liveKit)
    } else if viewModel.isStreaming {
      LiveKitStreamView(session: liveKit, glassesPlaceholder: glassesPlaceholder)
    } else if let wearablesViewModel {
      if wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice {
        LiveKitStreamView(session: liveKit, glassesPlaceholder: glassesPlaceholder)
          .task {
            guard !glassesAutoStarted else { return }
            glassesAutoStarted = true
            NSLog("[Stream] auto-start begin (waiting on glasses wake + BT handshake)")
            await viewModel.handleStartStreaming()
            for tick in 0..<180 {
              if viewModel.isStreaming || captureSource != .glasses { break }
              try? await Task.sleep(nanoseconds: 500_000_000)
              if tick > 0, tick % 20 == 0 { await viewModel.handleStartStreaming() }
            }
          }
      } else {
        HomeScreenView(viewModel: wearablesViewModel)
      }
    } else {
      Color.black.edgesIgnoringSafeArea(.all)
    }
  }

  private var studyOverlayLayer: some View {
    VStack {
      Spacer()
      if !studySolver.lastAnswer.isEmpty {
        Text(studySolver.lastAnswer)
          .font(.footnote)
          .foregroundStyle(.white)
          .lineLimit(5)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
          .padding(.horizontal, 20)
      }

      HStack(spacing: 10) {
        Button {
          tempApiKey = savedApiKey
          tempBaseURL = savedBaseURL
          tempModel = savedModel
          showKeyPrompt = true
        } label: {
          Image(systemName: "key.fill")
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.72), in: Circle())
        }

        Button {
          Task {
            await solveCurrentView()
          }
        } label: {
          HStack(spacing: 8) {
            if studySolver.isSolving {
              ProgressView()
                .tint(.white)
            } else {
              Image(systemName: "sparkles")
            }
            Text(studySolver.isSolving ? "Решаю..." : "Решить с камеры")
              .fontWeight(.semibold)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 18)
          .padding(.vertical, 12)
          .background(Color.blue.opacity(0.92), in: Capsule())
        }
        .disabled(studySolver.isSolving)
      }
      .padding(.bottom, 118)
    }
  }

  private var contentWithAlerts: some View {
    ZStack {
      mainStreamLayer
      studyOverlayLayer
    }
    .alert("Настройки API", isPresented: $showKeyPrompt) {
      TextField("API Key (sk-... или AIza...)", text: $tempApiKey)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      TextField("Base URL", text: $tempBaseURL)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      TextField("Модель (например hy4)", text: $tempModel)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Сохранить") {
        savedApiKey = tempApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        savedBaseURL = tempBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        savedModel = tempModel.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      Button("Отмена", role: .cancel) {}
    } message: {
      Text("Для ключа sk-... по умолчанию используется https://triklz27.ru/v1 и модель hy4.")
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  var body: some View {
    contentWithAlerts
      .task {
        setupFrameCallback()
        if captureSource == .iPhoneCamera {
          await liveKit.start()
        }
      }
      .onChange(of: viewModel.streamingStatus) { status in
        handleStatusChange(status == .streaming, isStopped: status == .stopped)
      }
      .onChange(of: intelligenceRaw) { _ in
        restartLiveKitIfNeeded()
      }
      .onChange(of: assistiveMode) { _ in
        restartLiveKitIfNeeded()
      }
      .onReceive(CallCommands.shared.startRequests) { _ in
        handleStartRequest()
      }
      .onReceive(CallCommands.shared.endRequests) { _ in
        Task {
          if liveKit.isActive { await liveKit.stop() }
        }
      }
      .onChange(of: captureSourceRaw) { newRaw in
        handleCaptureSourceChange(newRaw)
      }
      .onChange(of: viewModel.glassesIssue) { issue in
        handleGlassesIssue(issue)
      }
  }

  private func setupFrameCallback() {
    viewModel.onDecodedFrame = { [weak liveKit] pixelBuffer in
      liveKit?.pushGlassesFrame(pixelBuffer)
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
        let uiImage = UIImage(cgImage: cgImage)
        Task { @MainActor in
          latestGlassesImage = uiImage
        }
      }
    }
  }

  private func handleStatusChange(_ isStreaming: Bool, isStopped: Bool) {
    guard captureSource == .glasses else { return }
    Task {
      if isStreaming {
        await liveKit.start()
      } else if isStopped, liveKit.isActive {
        await liveKit.stop()
      }
    }
  }

  private func handleGlassesIssue(_ issue: StreamSessionViewModel.GlassesIssue?) {
    guard captureSource == .glasses,
          issue == StreamSessionViewModel.GlassesIssue.reconnecting else { return }
    let placeholder = glassesPlaceholder
    A11y.announce("\(placeholder.title). \(placeholder.caption)")
  }

  private func restartLiveKitIfNeeded() {
    Task {
      if liveKit.isActive {
        await liveKit.stop()
        await liveKit.start()
      }
    }
  }

  private func handleStartRequest() {
    Task {
      guard !liveKit.isActive else { return }
      let isGlasses = (captureSource == .glasses)
      if isGlasses && !viewModel.isStreaming {
        await viewModel.handleStartStreaming()
      } else {
        await liveKit.start()
      }
    }
  }

  private func handleCaptureSourceChange(_ newRaw: String) {
    glassesAutoStarted = false
    Task {
      if CaptureSource(rawValue: newRaw) == .iPhoneCamera {
        if viewModel.isStreaming { await viewModel.stopSession() }
        await liveKit.start()
      } else {
        await liveKit.stop()
      }
    }
  }

  @MainActor
  private func solveCurrentView() async {
    let apiKey = savedApiKey.isEmpty ? Secrets.geminiAPIKey : savedApiKey

    if let glassesImage = latestGlassesImage {
      await studySolver.solveStudyImage(glassesImage, apiKey: apiKey, customBaseURL: savedBaseURL, customModel: savedModel)
      return
    }

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
      let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
      let snapshot = renderer.image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
      }
      await studySolver.solveStudyImage(snapshot, apiKey: apiKey, customBaseURL: savedBaseURL, customModel: savedModel)
    }
  }
}
// END OF FILE
