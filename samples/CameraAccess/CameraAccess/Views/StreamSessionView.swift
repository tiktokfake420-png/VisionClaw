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

import CoreImage
import MWDATCore
import SwiftUI
import UIKit

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

  var body: some View {
    ZStack {
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

      // Автономная панель StudySolver (работает напрямую через Gemini API без Gateway)
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
      guard captureSource == .glasses else { return }
      Task {
        if status == .streaming {
          await liveKit.start()
        } else if status == .stopped, liveKit.isActive {
          await liveKit.stop()
        }
      }
    }
    .onChange(of: intelligenceRaw) { _ in
      Task {
        if liveKit.isActive {
          await liveKit.stop()
          await liveKit.start()
        }
      }
    }
    .onChange(of: assistiveMode) { _ in
      Task {
        if liveKit.isActive {
          await liveKit.stop()
          await liveKit.start()
        }
      }
    }
    .onReceive(CallCommands.shared.startRequests) { _ in
      Task {
        guard !liveKit.isActive else { return }
        if captureSource == .glasses, !viewModel.isStreaming {
          await viewModel.handleStartStreaming()
        } else {
          await liveKit.start()
        }
      }
    }
    .onReceive(CallCommands.shared.endRequests) { _ in
      Task {
        if liveKit.isActive { await liveKit.stop() }
      }
    }
    .onChange(of: captureSourceRaw) { newRaw in
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
