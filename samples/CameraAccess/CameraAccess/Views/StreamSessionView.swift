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
import MediaPlayer
import MWDATCore
import Speech
import SwiftUI
import UIKit

/// Which backend an API key is sent to. Decided by the key's prefix, so the
/// user only pastes a key and never has to pick a provider.
enum ApiProvider {
    /// Keys issued by triklz27.ru (sk-cvc-...). Always sent to triklz27.ru/v1.
    case triklz
    /// Any other sk-... key. Uses the Base URL from the key dialog, or OpenAI.
    case openAICompatible
    /// Google keys (AIza..., AQ....).
    case google

    static let triklzKeyPrefix = "sk-cvc-"
    static let triklzBaseURL = "https://triklz27.ru/v1"
    static let triklzDefaultModel = "hy4"
    static let openAIBaseURL = "https://api.openai.com/v1"
    static let openAIDefaultModel = "gpt-4o-mini"

    static func detect(_ key: String) -> ApiProvider {
        if key.hasPrefix(triklzKeyPrefix) { return .triklz }
        if key.hasPrefix("sk-") { return .openAICompatible }
        return .google
    }
}

@MainActor
final class GeminiStudySolver: NSObject, ObservableObject {
    @Published var isSolving: Bool = false
    @Published var lastAnswer: String = ""
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()

    /// True while a request is in flight or the answer is being read aloud.
    var isBusy: Bool { isSolving || synthesizer.isSpeaking }
    var isSpeaking: Bool { synthesizer.isSpeaking }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

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

        let provider = ApiProvider.detect(cleanKey)
        if provider != .google {
            await solveWithOpenAICompatible(
                base64Image: base64Image,
                prompt: prompt,
                apiKey: cleanKey,
                provider: provider,
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
        provider: ApiProvider,
        customBaseURL: String,
        customModel: String
    ) async {
        // sk-cvc- keys always go to triklz27.ru; the Base URL field only applies
        // to other sk-... keys.
        let base: String
        let defaultModel: String
        if provider == .triklz {
            base = ApiProvider.triklzBaseURL
            defaultModel = ApiProvider.triklzDefaultModel
        } else {
            let rawBase = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            base = rawBase.isEmpty
                ? ApiProvider.openAIBaseURL
                : rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            defaultModel = ApiProvider.openAIDefaultModel
        }

        let rawModel = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = rawModel.isEmpty ? defaultModel : rawModel

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

        // Same session as the hands-free listener (play and record), otherwise
        // speaking would switch the session to playback-only and kill the mic.
        HandsFreeAudio.configureSession()

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
}

/// Audio session shared by the answer voice and the hands-free listener.
enum HandsFreeAudio {
    static func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try? session.setActive(true)
    }
}

/// Starts "solve from camera" without touching the screen, two ways:
///  1. Tap on the glasses' temple (arrives as a Bluetooth media command: play/pause/next/previous).
///     iOS only delivers those to the app that is "Now Playing", so a silent loop is played.
///  2. Saying "решай" / "реши" (on-device speech recognition, mic of the glasses if connected).
/// The physical capture button of the glasses is NOT available to apps.
@MainActor
final class HandsFreeTrigger: NSObject, ObservableObject {
    enum Source { case temple, voice }

    @Published private(set) var triggerCount = 0
    @Published private(set) var lastSource: Source = .temple
    @Published private(set) var statusText = ""

    /// Set by the view: true while an answer is being solved or spoken.
    var isBusy: () -> Bool = { false }

    private let keywords = ["решай", "реши"]
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var silentPlayer: AVAudioPlayer?
    private var remoteTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var lastFire = Date.distantPast
    private var generation = 0
    private var failures = 0
    private var needsFlush = false
    private var running = false
    private var suspended = false

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        suspended = false
        activateAudio()
        installRemoteCommands()
        installObservers()
        requestPermissionsAndListen()
    }

    func stop() {
        running = false
        stopRecognition()
        removeRemoteCommands()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        silentPlayer?.stop()
        silentPlayer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        statusText = ""
    }

    /// A live voice call owns the microphone, so listening pauses while it is active.
    func setSuspended(_ value: Bool) {
        guard running, value != suspended else { return }
        suspended = value
        if value {
            stopRecognition()
            silentPlayer?.pause()
            statusText = "Пауза: идёт голосовой звонок"
        } else {
            activateAudio()
            startRecognition()
        }
    }

    // MARK: Temple tap (media commands)

    private func activateAudio() {
        HandsFreeAudio.configureSession()
        if silentPlayer == nil {
            silentPlayer = try? AVAudioPlayer(data: Self.silentWav())
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.prepareToPlay()
        }
        silentPlayer?.play()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "VisionClaw: скажи «решай» или коснись дужки",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func installRemoteCommands() {
        removeRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        let commands = [
            center.togglePlayPauseCommand, center.playCommand, center.pauseCommand,
            center.nextTrackCommand, center.previousTrackCommand,
        ]
        for command in commands {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.running, !self.suspended else { return }
                    self.fire(.temple)
                    // Stay "playing" so the next tap is still delivered to this app.
                    if self.silentPlayer?.isPlaying == false { self.silentPlayer?.play() }
                    MPNowPlayingInfoCenter.default().playbackState = .playing
                }
                return .success
            }
            remoteTargets.append((command, token))
        }
    }

    private func removeRemoteCommands() {
        for item in remoteTargets { item.command.removeTarget(item.token) }
        remoteTargets.removeAll()
    }

    private func fire(_ source: Source) {
        let now = Date()
        guard now.timeIntervalSince(lastFire) > 2.5 else { return }
        lastFire = now
        lastSource = source
        triggerCount += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startRecognition() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, self.running, !self.suspended else { return }
                if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    self.activateAudio()
                    self.startRecognition()
                }
            }
        })
    }

    // MARK: Voice keyword

    private func requestPermissionsAndListen() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.running else { return }
                guard status == .authorized else {
                    self.statusText = "Нет доступа к распознаванию речи. Касание дужки работает."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard self.running else { return }
                        if granted {
                            self.startRecognition()
                        } else {
                            self.statusText = "Нет доступа к микрофону. Касание дужки работает."
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in request.append(buffer) }
    }

    private func startRecognition() {
        guard running, !suspended else { return }
        guard let recognizer, recognizer.isAvailable else {
            statusText = "Распознавание речи недоступно. Касание дужки работает."
            scheduleRestart(after: 5)
            return
        }
        stopRecognition()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            scheduleRestart(after: 2)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: req))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failures += 1
            statusText = "Микрофон занят. Касание дужки работает."
            if failures < 6 { scheduleRestart(after: 3) }
            return
        }
        failures = 0
        request = req
        statusText = "Слушаю: скажи «решай» или коснись дужки"

        let gen = generation
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString.lowercased()
            let finished = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in self?.handle(text: text, finished: finished, generation: gen) }
        }
        // One recognition request lives for about a minute, so renew it before that.
        scheduleRestart(after: 50)
    }

    private func stopRecognition() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func scheduleRestart(after seconds: Double) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startRecognition()
        }
    }

    private func handle(text: String?, finished: Bool, generation gen: Int) {
        guard gen == generation, running, !suspended else { return }
        // Ignore the assistant's own voice: while it solves or speaks, drop what the mic hears.
        if isBusy() {
            needsFlush = true
            return
        }
        if needsFlush {
            needsFlush = false
            startRecognition()
            return
        }
        if let text, keywords.contains(where: { text.contains($0) }) {
            fire(.voice)
            startRecognition() // fresh transcript, so the same word is not counted twice
            return
        }
        if finished { scheduleRestart(after: 0.5) }
    }

    // MARK: Silent audio

    private static func silentWav() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2 // one second, 16-bit mono
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var liveKit = LiveKitSession()
  @StateObject private var studySolver = GeminiStudySolver()
  @StateObject private var handsFree = HandsFreeTrigger()
  @AppStorage("handsfree_enabled") private var handsFreeEnabled = true
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.openai.rawValue
  @AppStorage(SettingsManager.assistiveModeKey) private var assistiveMode = false
  @AppStorage("custom_gemini_api_key") private var savedApiKey: String = ""
  @AppStorage("custom_api_base_url") private var savedBaseURL: String = ""
  @AppStorage("custom_api_model") private var savedModel: String = ""
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

      if handsFreeEnabled, !handsFree.statusText.isEmpty {
        Text(handsFree.statusText)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.8))
          .padding(.bottom, 4)
      }

      HStack(spacing: 10) {
        Button {
          handsFreeEnabled.toggle()
        } label: {
          Image(systemName: handsFreeEnabled ? "ear.fill" : "ear")
            .foregroundStyle(handsFreeEnabled ? Color.green : Color.white)
            .padding(12)
            .background(.black.opacity(0.72), in: Circle())
        }

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
      TextField("API Key (sk-cvc-..., sk-... или AIza...)", text: $tempApiKey)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      TextField("Base URL (только для других sk-... ключей)", text: $tempBaseURL)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      TextField("Модель (пусто = по умолчанию)", text: $tempModel)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Сохранить") {
        savedApiKey = tempApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        savedBaseURL = tempBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        savedModel = tempModel.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      Button("Отмена", role: .cancel) {}
    } message: {
      Text("Ключ sk-cvc-... всегда идёт на https://triklz27.ru/v1 (модель по умолчанию hy4). Другие sk-... ключи используют Base URL из поля выше или https://api.openai.com/v1.")
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
        let solver = studySolver
        handsFree.isBusy = { [weak solver] in solver?.isBusy ?? false }
        if handsFreeEnabled {
          handsFree.start()
          handsFree.setSuspended(liveKit.isActive)
        }
      }
      .onReceive(liveKit.$state) { newState in
        handsFree.setSuspended(newState == .connected || newState == .connecting)
      }
      .onChange(of: handsFreeEnabled) { enabled in
        if enabled {
          handsFree.start()
          handsFree.setSuspended(liveKit.isActive)
        } else {
          handsFree.stop()
        }
      }
      .onChange(of: handsFree.triggerCount) { _ in
        handleHandsFreeTrigger()
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

  /// Temple tap or the word "решай": a tap while the answer is being read stops it,
  /// otherwise it takes a fresh frame and solves it.
  private func handleHandsFreeTrigger() {
    if studySolver.isSpeaking {
      studySolver.stopSpeaking()
      return
    }
    guard !studySolver.isSolving else { return }
    studySolver.speak("Смотрю")
    Task { await solveCurrentView() }
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
