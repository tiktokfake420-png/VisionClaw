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
  @State private var showKeyPrompt = false
  @State private var tempApiKey: String = ""
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

  var body: some View {
    ZStack {
      mainStreamLayer
      studyOverlayLayer
    }
    .alert("Gemini API Key", isPresented: $showKeyPrompt) {
      TextField("Вставьте API-ключ", text: $tempApiKey)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Сохранить") {
        savedApiKey = tempApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      Button("Отмена", role: .cancel) {}
    } message: {
      Text("Ключ сохранится только на вашем iPhone.")
    }
    .task {
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
      if captureSource == .iPhoneCamera {
        await liveKit.start()
      }
    }
    .onChange(of: viewModel.streamingStatus) { status in
      handleStreamingStatusChange(status)
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
      guard captureSource == .glasses,
            issue == StreamSessionViewModel.GlassesIssue.reconnecting else { return }
      let placeholder = glassesPlaceholder
      A11y.announce("\(placeholder.title). \(placeholder.caption)")
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  private func handleStreamingStatusChange(_ status: StreamSessionViewModel.StreamingStatus) {
    guard captureSource == .glasses else { return }
    Task {
      if status == .streaming {
        await liveKit.start()
      } else if status == .stopped, liveKit.isActive {
        await liveKit.stop()
      }
    }
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
      await studySolver.solveStudyImage(glassesImage, apiKey: apiKey)
      return
    }

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
      let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
      let snapshot = renderer.image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
      }
      await studySolver.solveStudyImage(snapshot, apiKey: apiKey)
    }
  }
}
