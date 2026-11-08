//
//  TranslationQueueWindow.swift
//  iina
//
//  The Translation Queue window: what to translate into and with what, a place to drop videos and subtitle files, and
//  the queue as a list of cards. Laid out like the queue page of the Subtitle Overlay extension, drawn in Liquid Glass
//  on macOS 26 and later (materials before that).
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class TranslationQueueWindowController: NSWindowController {

  static let shared = TranslationQueueWindowController()

  private init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
    window.title = "Translation Queue"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 460, height: 440)
    window.collectionBehavior = [.fullScreenAuxiliary]

    // The window itself is a frosted pane over the desktop; the cards on it are glass.
    let background = NSVisualEffectView()
    background.material = .underWindowBackground
    background.blendingMode = .behindWindow
    background.state = .followsWindowActiveState
    let hosting = NSHostingView(rootView: TranslationQueueView(queue: .shared))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: background.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    window.contentView = background
    super.init(window: window)
    window.center()
    window.setFrameAutosaveName("TranslationQueue")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - Glass

private extension View {
  /// A glass card on macOS 26 and later, a material card before.
  @ViewBuilder func glassCard(cornerRadius: CGFloat = 18) -> some View {
#if MACOS_26_AVAILABLE
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
#else
    background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
#endif
  }

  @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
#if MACOS_26_AVAILABLE
    if #available(macOS 26.0, *) {
      if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    } else {
      if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
#else
    if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
#endif
  }
}

/// Groups glass cards so neighbouring ones blend as they move (macOS 26 and later).
private struct GlassGroup<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  var body: some View {
#if MACOS_26_AVAILABLE
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
#else
    content
#endif
  }
}

// MARK: - The window's content

struct TranslationQueueView: View {
  @ObservedObject var queue: TranslationQueue

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Videos and subtitle files are translated one after another, while you watch or do something else. The video you're playing always goes first; the queue waits for it.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        TranslatorSettingsCard()
        DropArea(queue: queue)
        QueueList(queue: queue)
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 24)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
  }
}

// MARK: Settings

private struct TranslatorSettingsCard: View {
  @AppStorage(Preference.Key.subTranslateEngine.rawValue) private var engineRaw = TranslationEngine.google.rawValue
  @AppStorage(Preference.Key.subTranslateLang.rawValue) private var langRaw = ""
  @AppStorage(Preference.Key.subTranslateSaveNextToOriginal.rawValue) private var saveNextToOriginal = true
  /// Bumped when a model is chosen, which is saved outside SwiftUI's knowledge.
  @State private var modelRevision = 0
  @StateObject private var models = ModelList()

  private var engine: TranslationEngine { TranslationEngine(rawValue: engineRaw) ?? .google }

  var body: some View {
    let _ = modelRevision
    VStack(alignment: .leading, spacing: 14) {
      row("Translate to") {
        Picker("", selection: Binding(get: { SubtitleTranslator.targetLanguage },
                                      set: { SubtitleTranslator.targetLanguage = $0 })) {
          ForEach(SubtitleTranslator.languages, id: \.code) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
        .frame(maxWidth: 220, alignment: .leading)
        .id(langRaw)
      }

      VStack(alignment: .leading, spacing: 6) {
        row("Translator") {
          Picker("", selection: $engineRaw) {
            ForEach(TranslationEngine.allCases, id: \.rawValue) { Text($0.shortTitle).tag($0.rawValue) }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(maxWidth: 330, alignment: .leading)
        }
        Text(engine.help)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if engine.isLanguageModel {
        if engine.needsKey && engine.apiKey.isEmpty {
          row("API key") {
            Text("Not added yet").foregroundStyle(.secondary)
            Button("Open Settings…") { Self.openSettings() }.glassButton()
          }
        } else {
          row("Model") {
            Picker("", selection: Binding(get: { engine.model.isEmpty ? (models.picked ?? "") : engine.model },
                                          set: { engine.model = $0; modelRevision += 1 })) {
              if models.models.isEmpty { Text(models.isLoading ? "Loading…" : "None").tag("") }
              ForEach(models.models, id: \.self) { Text($0).tag($0) }
              if !engine.model.isEmpty && !models.models.contains(engine.model) { Text(engine.model).tag(engine.model) }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize()
            Button { models.load(engine) } label: { Image(systemName: "arrow.clockwise") }
              .help("Load the list of models again")
              .glassButton()
          }
          if let status = models.status {
            Text(status)
              .font(.callout)
              .foregroundStyle(models.failed ? Color.red : Color.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      Divider().opacity(0.5)

      Toggle(isOn: $saveNextToOriginal) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Save each translation next to the original")
          Text("As \"Movie.cs.translated.srt\" beside the video, so it's in the subtitle list when you play it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
    }
    .padding(18)
    .glassCard()
    .onAppear { models.load(engine) }
    .onChange(of: engineRaw) { _ in models.load(engine) }
  }

  private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 10) {
      Text(title).frame(width: 96, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
  }

  static func openSettings() {
    guard let controller = (NSApp.delegate as? AppDelegate)?.preferenceWindowController,
          let pane = controller.openPreferenceView(withNibName: "PrefSubViewController") as? PrefSubViewController else { return }
    DispatchQueue.main.async { pane.revealTranslationSettings() }
  }
}

/// The models the chosen service offers, loaded when the window opens or the translator changes.
@MainActor
private final class ModelList: ObservableObject {
  @Published var models: [String] = []
  @Published var picked: String?
  @Published var status: String?
  @Published var failed = false
  @Published var isLoading = false
  private var task: Task<Void, Never>?

  func load(_ engine: TranslationEngine) {
    task?.cancel()
    models = []
    picked = nil
    status = nil
    failed = false
    guard engine.isLanguageModel, !engine.needsKey || !engine.apiKey.isEmpty else { return }
    isLoading = true
    task = Task {
      do {
        let list = try await LanguageModelClient.listModels(engine)
        guard !Task.isCancelled else { return }
        models = list
        picked = LanguageModelClient.pickModel(engine, from: list)
        status = list.isEmpty ? (engine == .local ? "No model is installed. In Terminal, run: ollama pull gemma3:12b"
                                                  : "No models found for this key.") : nil
        failed = list.isEmpty
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        status = error.localizedDescription
        failed = true
      }
      isLoading = false
    }
  }
}

// MARK: Adding files

private struct DropArea: View {
  @ObservedObject var queue: TranslationQueue
  @State private var isTargeted = false

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "captions.bubble")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
      Text("Drop videos, subtitle files or a folder of episodes here")
        .foregroundStyle(isTargeted ? .primary : .secondary)
        .multilineTextAlignment(.center)
      HStack(spacing: 10) {
        Button("Choose Files…", action: choose).glassButton(prominent: true)
        if queue.isAdding {
          ProgressView().controlSize(.small)
          Text("Reading subtitles…").font(.callout).foregroundStyle(.secondary)
        }
      }
      if !queue.message.isEmpty {
        Text(queue.message)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 26)
    .padding(.horizontal, 16)
    .glassCard()
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        .padding(6)
    )
    .scaleEffect(isTargeted ? 1.01 : 1)
    .animation(.easeOut(duration: 0.15), value: isTargeted)
    .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
      let collected = DroppedURLs()
      let group = DispatchGroup()
      for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          if let url { collected.append(url) }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        Task { @MainActor in queue.add(urls: collected.urls) }
      }
      return true
    }
    .help("Each file is translated into the language chosen above. For a video, IINA takes a subtitle file next to it, otherwise the text subtitles inside it, in your preferred subtitle language if there are several.")
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.prompt = "Add to Queue"
    panel.message = "Choose videos, subtitle files or folders to translate."
    guard panel.runModal() == .OK else { return }
    queue.add(urls: panel.urls)
  }
}

/// File URLs from a drop, which arrive one by one on background threads.
private final class DroppedURLs: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [URL] = []
  var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
  func append(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
}

// MARK: The queue

private struct QueueList: View {
  @ObservedObject var queue: TranslationQueue

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Queue").font(.title3.weight(.semibold))
        Spacer()
        if queue.hasWaiting || queue.paused {
          Button {
            queue.setPaused(!queue.paused)
          } label: {
            Label(queue.paused ? "Resume" : "Pause", systemImage: queue.paused ? "play.fill" : "pause.fill")
          }
          .glassButton()
        }
        if queue.jobs.contains(where: { $0.status == .done }) {
          Button("Clear Finished") { queue.clearFinished() }.glassButton()
        }
      }
      if queue.jobs.isEmpty {
        Text("Nothing in the queue yet.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        GlassGroup(spacing: 10) {
          VStack(spacing: 10) {
            ForEach(queue.jobs) { job in
              JobCard(job: job, queue: queue)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
          }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: queue.jobs.map(\.id))
      }
    }
  }
}

private struct JobCard: View {
  let job: TranslationJob
  @ObservedObject var queue: TranslationQueue

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        statusIcon
        Text(job.name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(job.videoPath ?? job.subtitlePath ?? job.name)
        if job.isLive {
          Text("Playing now")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        Spacer(minLength: 4)
        Text(SubtitleTranslator.languageName(job.lang))
          .font(.callout)
          .foregroundStyle(.secondary)
        Button { queue.remove(job.id) } label: {
          Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(job.isLive || job.status == .running ? "Stop and remove" : "Remove from the queue")
      }

      progressBar

      HStack(spacing: 8) {
        Text(TranslationQueue.note(for: job, paused: queue.paused))
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(job.status == .error ? Color.red : Color.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        actions
      }
    }
    .padding(14)
    .glassCard(cornerRadius: 16)
  }

  @ViewBuilder private var statusIcon: some View {
    switch job.status {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .error:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .running:
      Image(systemName: job.isLive ? "play.circle.fill" : "text.bubble.fill").foregroundStyle(Color.accentColor)
    case .waiting:
      Image(systemName: "clock").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var progressBar: some View {
    let tint: Color = job.status == .done ? .green : job.status == .error ? .red : .accentColor
    if job.status == .running && job.linesDone == 0 {
      ProgressView().progressViewStyle(.linear).tint(tint)
    } else {
      ProgressView(value: job.progress).progressViewStyle(.linear).tint(tint)
    }
  }

  @ViewBuilder private var actions: some View {
    switch job.status {
    case .waiting where !job.isLive:
      if queue.canMove(job.id, by: -1) || queue.canMove(job.id, by: 1) {
        HStack(spacing: 2) {
          Button { queue.move(job.id, by: -1) } label: { Image(systemName: "arrow.up") }
            .disabled(!queue.canMove(job.id, by: -1))
            .help("Move up")
          Button { queue.move(job.id, by: 1) } label: { Image(systemName: "arrow.down") }
            .disabled(!queue.canMove(job.id, by: 1))
            .help("Move down")
        }
        .buttonStyle(.borderless)
      }
    case .error:
      Button("Try Again") { queue.retry(job.id) }.glassButton()
    case .done:
      if job.videoPath != nil {
        Button("Play") { queue.play(job) }
          .glassButton(prominent: true)
          .help("Opens the video with this translation.")
      }
      if let url = queue.outputURL(of: job) {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
          .help("Show the translated subtitle file in Finder")
          .glassButton()
      }
    default:
      EmptyView()
    }
  }
}
