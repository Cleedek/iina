//
//  TranslationQueue.swift
//  iina
//
//  Every subtitle translation runs here, one at a time: the video being watched goes first, then the files added to the
//  queue, top to bottom. Modelled on the translation queue of the Subtitle Overlay extension: a model translates 30
//  lines at a time with notes on who is who, Google Translate fills in what the model leaves out, a failed request is
//  asked again after a wait, and the queue is saved, so it carries on where it was after IINA restarts.
//

import Foundation
import Combine

struct TranslationJob: Codable, Identifiable, Equatable {
  enum Status: String, Codable { case waiting, running, done, error }

  let id: UUID
  var name: String
  /// The video the subtitles belong to, if any.
  var videoPath: String?
  /// The subtitle file the text comes from, if it isn't inside the video.
  var subtitlePath: String?
  /// Place among the video's subtitle streams, for subtitles inside the video.
  var streamOrdinal: Int?
  /// The source as the translation cache knows it: video, track and the track's language.
  var sourceKey: String
  var lang: String
  var cues: [SubtitleTranslator.Cue] = []
  /// The model's translation of each line (HTML), nil until it is done or if the model left it out.
  var out: [String?] = []
  /// First line of each chunk the model went through.
  var chunks: [Int] = []
  /// Notes on who is who, made once per file.
  var sheet: String?
  var status: Status = .waiting
  var error = ""
  var model = ""
  var outputPath: String?
  /// Shown while a failed request waits to be asked again. Not saved.
  var retry = ""
  /// The video playing now: translated first, shown as it goes, and not saved.
  var isLive = false

  enum CodingKeys: String, CodingKey {
    case id, name, videoPath, subtitlePath, streamOrdinal, sourceKey, lang, cues, out, chunks, sheet, status, error,
         model, outputPath
  }

  var linesDone: Int {
    if status == .done { return cues.count }
    return chunks.reduce(0) { $0 + min(LanguageModelTranslator.chunkLines, cues.count - $1) }
  }

  var progress: Double { cues.isEmpty ? 0 : Double(linesDone) / Double(cues.count) }
}

@MainActor
final class TranslationQueue: ObservableObject {

  static let shared = TranslationQueue()

  /// The queue, top to bottom. Translations of the videos playing now are at the top.
  @Published private(set) var jobs: [TranslationJob] = []
  @Published private(set) var paused = false
  /// A note under the drop area, such as files that were left out.
  @Published var message = ""
  @Published private(set) var isAdding = false

  /// What a translation of a video playing now needs besides the job.
  private struct Live {
    weak var player: PlayerCore?
    let track: MPVTrack
    let videoURL: URL
    let placement: TranslationPlacement
    let position: Double
    let ordinal: Int
    let encoding: String?
  }
  private var live: [UUID: Live] = [:]
  private var runner: Task<Void, Never>?
  private var current: (id: UUID, task: Task<Void, Never>)?

  private static let fileURL = Utility.appSupportDirUrl.appendingPathComponent("translation-queue.json")
  private struct Stored: Codable {
    var jobs: [TranslationJob]
    var paused: Bool
  }

  private init() {
    if let data = try? Data(contentsOf: Self.fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
      jobs = stored.jobs.map { job in
        var job = job
        if job.status == .running { job.status = .waiting }
        return job
      }
      paused = stored.paused
    }
    kick()
  }

  private func save() {
    let stored = Stored(jobs: jobs.filter { !$0.isLive }, paused: paused)
    do {
      try JSONEncoder().encode(stored).write(to: Self.fileURL, options: .atomic)
    } catch {
      Logger.log("Cannot save the translation queue: \(error.localizedDescription)", level: .error)
    }
  }

  private func update(_ id: UUID, _ change: (inout TranslationJob) -> Void) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    change(&jobs[index])
  }

  private func job(_ id: UUID) -> TranslationJob? { jobs.first { $0.id == id } }

  // MARK: - The video playing now

  func liveJob(for player: PlayerCore) -> TranslationJob? {
    jobs.first { job in job.isLive && live[job.id]?.player === player }
  }

  /// Translates the subtitles of the video playing now. It goes before the files in the queue: a file being translated
  /// stops at once and carries on afterwards from the chunk it was at.
  func translateLive(player: PlayerCore, track: MPVTrack, videoURL: URL, lang: String) {
    let ordinal = SubtitleTranslator.streamOrdinal(of: track, in: player)
    let sourceKey = SubtitleTranslator.sourceKey(video: videoURL, subtitleFile: track.externalFilename, streamOrdinal: ordinal)
    if let running = liveJob(for: player) {
      if running.sourceKey == sourceKey && running.lang == lang {
        player.sendOSD(.custom(Self.note(for: running, paused: false)))
        return
      }
      remove(running.id)
    }
    var job = TranslationJob(id: UUID(), name: videoURL.lastPathComponent, sourceKey: sourceKey, lang: lang)
    job.isLive = true
    if videoURL.isFileURL { job.videoPath = videoURL.path }
    live[job.id] = Live(player: player, track: track, videoURL: videoURL, placement: .current,
                        position: player.info.videoPosition?.second ?? 0,
                        ordinal: ordinal,
                        encoding: player.info.subEncoding)
    let liveCount = jobs.filter(\.isLive).count
    jobs.insert(job, at: liveCount)
    if let current, self.job(current.id)?.isLive == false { current.task.cancel() }
    kick()
  }

  func stopLive(player: PlayerCore) {
    guard let job = liveJob(for: player) else { return }
    remove(job.id)
    player.sendOSD(.custom("Translation stopped"))
  }

  // MARK: - Adding files

  /// Adds videos (their subtitles: a subtitle file next to the video, otherwise the subtitles inside it), subtitle
  /// files, or folders of them. Each is translated into the language chosen now.
  func add(urls: [URL]) {
    let lang = SubtitleTranslator.targetLanguage
    let preferred = (Preference.string(for: .subLang) ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    isAdding = true
    message = ""
    Task {
      let files = await Task.detached { Self.expand(urls) }.value
      var skipped: [String] = []
      for url in files {
        do {
          var job = try await Task.detached { try Self.makeJob(url, lang: lang, preferred: preferred) }.value
          if jobs.contains(where: { $0.sourceKey == job.sourceKey && $0.lang == job.lang && $0.status != .done }) { continue }
          job.out = Array(repeating: nil, count: job.cues.count)
          jobs.append(job)
          save()
          kick()
        } catch {
          skipped.append("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
      }
      isAdding = false
      message = skipped.isEmpty ? "" : "Left out: " + skipped.joined(separator: "; ")
    }
  }

  /// Adds the subtitles of the video playing now, to translate them later.
  func add(player: PlayerCore) {
    guard let track = SubtitleTranslator.sourceTrack(for: player), let url = player.info.currentURL, url.isFileURL else {
      player.sendOSD(.customWithDetail("Nothing to add", "Choose a text subtitle track of a video on this Mac first."))
      return
    }
    let lang = SubtitleTranslator.targetLanguage
    let ordinal = SubtitleTranslator.streamOrdinal(of: track, in: player)
    let encoding = player.info.subEncoding
    var job = TranslationJob(id: UUID(), name: url.lastPathComponent, videoPath: url.path,
                             subtitlePath: track.externalFilename, streamOrdinal: track.isExternal ? nil : ordinal,
                             sourceKey: SubtitleTranslator.sourceKey(video: url, subtitleFile: track.externalFilename,
                                                                     streamOrdinal: ordinal), lang: lang)
    Task {
      do {
        job.cues = try await Task.detached {
          try SubtitleTranslator.readCues(file: track.externalFilename ?? url.path, ordinal: track.isExternal ? 0 : ordinal,
                                          external: track.isExternal, encoding: encoding)
        }.value
        job.out = Array(repeating: nil, count: job.cues.count)
        jobs.append(job)
        save()
        kick()
        player.sendOSD(.custom("Added to the translation queue"))
      } catch {
        player.sendOSD(.customWithDetail("Can't add these subtitles", error.localizedDescription))
      }
    }
  }

  nonisolated private static let subtitleExtensions: Set<String> = ["srt", "vtt", "webvtt", "ass", "ssa"]

  nonisolated private static func expand(_ urls: [URL]) -> [URL] {
    let wanted = subtitleExtensions.union(Utility.supportedFileExt[.video]!)
    var files: [URL] = []
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
          .compactMap { $0 as? URL } ?? []
        // A folder of episodes with their subtitles: the videos, which find their subtitles themselves.
        let videos = found.filter { Utility.supportedFileExt[.video]!.contains($0.pathExtension.lowercased()) }
        let chosen = videos.isEmpty ? found.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) } : videos
        files += chosen.filter { !isOwnOutput($0) }
          .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
      } else if wanted.contains(url.pathExtension.lowercased()) {
        files.append(url)
      }
    }
    return files
  }

  nonisolated private static func isOwnOutput(_ url: URL) -> Bool {
    url.deletingPathExtension().pathExtension == "translated"
  }

  /// The English name of a language code, to compare codes of different kinds ("cs", "cze", "ces").
  nonisolated private static func languageName(_ code: String) -> String {
    ISO639Helper.dictionary[code.lowercased()]?.split(separator: ";").first.map(String.init) ?? code.lowercased()
  }

  nonisolated private static func makeJob(_ url: URL, lang: String, preferred: [String]) throws -> TranslationJob {
    let wantedNames = preferred.map(languageName)
    let rank = { (code: String?) -> Int in
      guard let code else { return wantedNames.count }
      return wantedNames.firstIndex(of: languageName(code)) ?? wantedNames.count
    }
    var job: TranslationJob
    if subtitleExtensions.contains(url.pathExtension.lowercased()) {
      job = TranslationJob(id: UUID(), name: url.lastPathComponent, subtitlePath: url.path,
                           sourceKey: "|\(url.absoluteString)|", lang: lang)
      job.cues = try SubtitleTranslator.readCues(file: url.path, ordinal: 0, external: true, encoding: nil)
      return job
    }
    // A video: the subtitle file next to it if there is one (one you found and put there), in the preferred language
    // if there are several, otherwise the text subtitles inside it.
    let base = url.deletingPathExtension().lastPathComponent
    let neighbours = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    let sidecars = neighbours.filter {
      subtitleExtensions.contains($0.pathExtension.lowercased()) && !isOwnOutput($0)
        && ($0.deletingPathExtension().lastPathComponent == base || $0.lastPathComponent.hasPrefix(base + "."))
    }
    let languageOf = { (sub: URL) -> String? in
      let suffix = sub.deletingPathExtension().pathExtension
      return suffix.isEmpty ? nil : suffix
    }
    if let sidecar = sidecars.min(by: { rank(languageOf($0)) < rank(languageOf($1)) }) {
      job = TranslationJob(id: UUID(), name: url.lastPathComponent, videoPath: url.path, subtitlePath: sidecar.path,
                           sourceKey: SubtitleTranslator.sourceKey(video: url, subtitleFile: sidecar.path, streamOrdinal: 0),
                           lang: lang)
      job.cues = try SubtitleTranslator.readCues(file: sidecar.path, ordinal: 0, external: true, encoding: nil)
      return job
    }
    guard let streams = FFmpegController.subtitleStreams(inFile: url.path) else {
      throw TranslationServiceError("the file could not be opened")
    }
    let text = streams.filter { $0["isText"] as? Bool == true }
    guard let stream = text.min(by: { rank($0["language"] as? String) < rank($1["language"] as? String) }),
          let ordinal = stream["ordinal"] as? Int else {
      throw TranslationServiceError(streams.isEmpty ? "no subtitles" : "its subtitles are pictures, not text")
    }
    job = TranslationJob(id: UUID(), name: url.lastPathComponent, videoPath: url.path, streamOrdinal: ordinal,
                         sourceKey: SubtitleTranslator.sourceKey(video: url, subtitleFile: nil, streamOrdinal: ordinal),
                         lang: lang)
    job.cues = try SubtitleTranslator.readCues(file: url.path, ordinal: ordinal, external: false, encoding: nil)
    return job
  }

  // MARK: - Changing the queue

  func remove(_ id: UUID) {
    if current?.id == id { current?.task.cancel() }
    jobs.removeAll { $0.id == id }
    live[id] = nil
    save()
  }

  /// Swaps a waiting file with the waiting file above (-1) or below (+1) it.
  func move(_ id: UUID, by offset: Int) {
    let waiting = jobs.indices.filter { jobs[$0].status == .waiting && !jobs[$0].isLive }
    guard let at = waiting.firstIndex(where: { jobs[$0].id == id }), waiting.indices.contains(at + offset) else { return }
    jobs.swapAt(waiting[at], waiting[at + offset])
    save()
  }

  func canMove(_ id: UUID, by offset: Int) -> Bool {
    let waiting = jobs.filter { $0.status == .waiting && !$0.isLive }
    guard let at = waiting.firstIndex(where: { $0.id == id }) else { return false }
    return waiting.indices.contains(at + offset)
  }

  func retry(_ id: UUID) {
    update(id) { $0.status = .waiting; $0.error = "" }
    save()
    kick()
  }

  func setPaused(_ value: Bool) {
    paused = value
    if value, let current, job(current.id)?.isLive == false { current.task.cancel() }
    save()
    kick()
  }

  func clearFinished() {
    jobs.removeAll { $0.status == .done }
    save()
  }

  var hasWaiting: Bool { jobs.contains { $0.status == .waiting || $0.status == .running } }

  // MARK: - Using finished files

  func outputURL(of job: TranslationJob) -> URL? {
    job.outputPath.map(URL.init(fileURLWithPath:))
  }

  /// Opens the video and shows the translation over it.
  func play(_ job: TranslationJob) {
    guard let video = job.videoPath, let output = outputURL(of: job) else { return }
    let player = PlayerCore.active
    final class Token: @unchecked Sendable { var observer: NSObjectProtocol? }
    let token = Token()
    token.observer = NotificationCenter.default.addObserver(forName: .iinaFileLoaded, object: player, queue: .main) { _ in
      if let observer = token.observer { NotificationCenter.default.removeObserver(observer) }
      guard player.info.currentURL?.path == video else { return }
      // A file that has just opened picks its subtitles when playback starts (primary off, the preferred track as a
      // hidden secondary). Wait for that, so it doesn't undo the translation chosen here.
      Task { @MainActor in
        for _ in 0..<50 where player.info.justOpenedFile { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard player.info.currentURL?.path == video else { return }
        SubtitleTranslator.show(output, title: SubtitleTranslator.trackTitle(lang: job.lang, model: job.model), lang: job.lang,
                                player: player, source: SubtitleTranslator.sourceTrack(for: player), placement: .current)
      }
    }
    player.openURL(URL(fileURLWithPath: video))
  }

  // MARK: - Running

  private func kick() {
    guard runner == nil else { return }
    runner = Task {
      while let next = nextJob() {
        let task = Task { await work(next.id) }
        current = (next.id, task)
        await task.value
        current = nil
      }
      runner = nil
    }
  }

  private func nextJob() -> TranslationJob? {
    if let live = jobs.first(where: { $0.isLive && $0.status == .waiting }) { return live }
    return paused ? nil : jobs.first { !$0.isLive && $0.status == .waiting }
  }

  private func work(_ id: UUID) async {
    guard let start = job(id) else { return }
    let liveInfo = live[id]
    update(id) { $0.status = .running; $0.error = "" }
    var shown = false
    do {
      let engine = TranslationEngine.current
      let lang = start.lang, langName = SubtitleTranslator.languageName(lang)
      let model = engine.isLanguageModel ? try await LanguageModelClient.resolveModel(engine) : ""
      let googleHelps = engine == .google || Preference.bool(for: .subTranslateGoogleHelp)
      update(id) { $0.model = model }

      if start.cues.isEmpty, let liveInfo {
        let cues = try await Task.detached {
          try SubtitleTranslator.readCues(track: liveInfo.track, videoURL: liveInfo.videoURL, ordinal: liveInfo.ordinal,
                                          encoding: liveInfo.encoding)
        }.value
        update(id) { $0.cues = cues; $0.out = Array(repeating: nil, count: cues.count) }
      }
      guard var job = job(id) else { throw CancellationError() }
      let total = job.cues.count
      let videoURL = liveInfo?.videoURL ?? URL(fileURLWithPath: job.videoPath ?? job.subtitlePath ?? job.name)
      let output = SubtitleTranslator.outputURL(sourceKey: job.sourceKey, video: videoURL, lang: lang, engine: engine, model: model)
      // Exists while the file holds only part of the translation, so an interrupted one is done again next time.
      let marker = output.appendingPathExtension("incomplete")
      let title = SubtitleTranslator.trackTitle(lang: lang, model: engine.isLanguageModel ? model : engine.title)
      let fileManager = FileManager.default
      let htmls = job.cues.map { SubtitleTranslator.toHtml($0.text) }

      // Shows what is ready over the video playing now. False once that video is no longer playing.
      func present(_ texts: [String?]) async throws {
        guard let liveInfo else { return }
        let ready = job.cues.indices.compactMap { i in
          texts[i].map { SubtitleTranslator.Cue(start: job.cues[i].start, end: job.cues[i].end, text: SubtitleTranslator.fromHtml($0)) }
        }
        try SubtitleTranslator.writeSRT(ready, to: output)
        guard let player = liveInfo.player, player.info.currentURL == liveInfo.videoURL, player.info.state.active else {
          throw CancellationError()
        }
        if shown {
          SubtitleTranslator.reload(output, title: title, lang: lang, player: player)
        } else {
          SubtitleTranslator.show(output, title: title, lang: lang, player: player, source: liveInfo.track,
                                  placement: liveInfo.placement)
          shown = true
        }
      }

      if job.chunks.isEmpty && fileManager.fileExists(atPath: output.path) && !fileManager.fileExists(atPath: marker.path) {
        // Translated before: nothing to do.
        if let liveInfo, let player = liveInfo.player, player.info.currentURL == liveInfo.videoURL {
          SubtitleTranslator.show(output, title: title, lang: lang, player: player, source: liveInfo.track,
                                  placement: liveInfo.placement)
          player.sendOSD(.custom("Subtitles translated to \(langName)"))
        }
        finish(id, output: output)
        return
      }

      liveInfo?.player?.sendOSD(.customWithDetail("Translating subtitles to \(langName)…", !engine.isLanguageModel
        ? "With \(engine.title)."
        : googleHelps ? "Google's version shows first, then \(model) improves it bit by bit, starting where you are."
        : "With \(model). They appear bit by bit, starting where you are."))
      fileManager.createFile(atPath: marker.path, contents: nil)

      // Google: the whole file in a few seconds. With a model: Google's quick version over the video right away, and
      // later what the model left out.
      var google: [String]?
      // The model's lines where it has done them, Google's elsewhere.
      let merged = { (out: [String?]) -> [String?] in
        guard let google else { return out }
        return out.indices.map { out[$0] ?? google[$0] }
      }
      if engine == .google || (googleHelps && liveInfo != nil) {
        do {
          google = try await SubtitleTranslator.googleTranslateAll(htmls, to: lang)
          if engine.isLanguageModel { try await present(merged(job.out)) }
        } catch is CancellationError {
          throw CancellationError()
        } catch where engine.isLanguageModel {
          Logger.log("Google's quick version didn't work, going on with the model: \(error.localizedDescription)", level: .warning)
        }
      }

      if engine.isLanguageModel {
        if job.sheet == nil {
          let sheet = try await LanguageModelTranslator.sheet(htmls, to: langName, engine: engine, model: model)
          update(id) { $0.sheet = sheet }
          if !job.isLive { save() }
        }
        job = self.job(id) ?? job
        let sheet = job.sheet ?? ""
        // From the current position for the video playing now, so the next minutes are ready first.
        var starts = Array(stride(from: 0, to: total, by: LanguageModelTranslator.chunkLines))
        if let liveInfo, let first = starts.firstIndex(where: { job.cues[min($0 + LanguageModelTranslator.chunkLines, total) - 1].end >= liveInfo.position }) {
          starts = Array(starts[first...] + starts[..<first])
        }
        starts.removeAll { job.chunks.contains($0) }
        let waits: [UInt64] = job.isLive ? [3, 10] : [30, 120]
        var lastShown = Date()

        try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
          var next = 0
          func addNext() {
            let start = starts[next]
            next += 1
            let lines = Array(htmls[start..<min(start + LanguageModelTranslator.chunkLines, total)])
            let before = Array(htmls[max(0, start - LanguageModelTranslator.contextLines)..<start])
            group.addTask {
              let texts = try await Self.retrying(waits: waits, onWait: { message in
                await MainActor.run { TranslationQueue.shared.update(id) { $0.retry = message } }
              }) {
                try await LanguageModelTranslator.translate(lines, before: before, sheet: sheet, to: langName,
                                                            engine: engine, model: model)
              }
              return (start, texts)
            }
          }
          while next < min(engine.concurrency, starts.count) { addNext() }
          while let (start, texts) = try await group.next() {
            update(id) { job in
              for (k, text) in texts.enumerated() where !text.isEmpty { job.out[start + k] = text }
              job.chunks.append(start)
              job.retry = ""
            }
            if next < starts.count { addNext() }
            guard let now = self.job(id) else { throw CancellationError() }
            job = now
            if !job.isLive { save() }
            // Every few seconds, what the model has done so far replaces Google's lines over the video.
            if liveInfo != nil && (!shown || Date().timeIntervalSince(lastShown) > 5) && job.linesDone < total {
              try await present(merged(job.out))
              lastShown = Date()
            }
          }
        }

        // The lines the model left out: Google's, if it may help, otherwise the original.
        job = self.job(id) ?? job
        let gaps = job.out.indices.filter { job.out[$0] == nil }
        if !gaps.isEmpty && googleHelps && google == nil {
          google = Array(htmls)
          if let filled = try? await SubtitleTranslator.googleTranslateAll(gaps.map { htmls[$0] }, to: lang) {
            for (n, i) in gaps.enumerated() { google![i] = filled[n] }
          }
        }
      }

      guard let finished = self.job(id) else { throw CancellationError() }
      job = finished
      let texts = job.cues.indices.map { job.out[$0] ?? google?[$0] ?? htmls[$0] }
      var cues = job.cues
      for i in cues.indices { cues[i].text = SubtitleTranslator.fromHtml(texts[i]) }
      try SubtitleTranslator.writeSRT(cues, to: output)
      try? fileManager.removeItem(at: marker)

      if let liveInfo, let player = liveInfo.player, player.info.currentURL == liveInfo.videoURL, player.info.state.active {
        if shown {
          SubtitleTranslator.reload(output, title: title, lang: lang, player: player)
        } else {
          SubtitleTranslator.show(output, title: title, lang: lang, player: player, source: liveInfo.track,
                                  placement: liveInfo.placement)
        }
        player.sendOSD(.custom("Subtitles translated to \(langName)"))
      }
      finish(id, output: output)
    } catch is CancellationError {
      // Stopped, removed or paused, or the video playing now went first: a file carries on from its chunk later.
      if job(id)?.isLive == true {
        remove(id)
      } else {
        update(id) { $0.status = .waiting; $0.retry = "" }
        save()
      }
    } catch {
      Logger.log("Subtitle translation failed: \(error.localizedDescription)", level: .error)
      if let liveInfo {
        liveInfo.player?.sendOSD(.customWithDetail("Translation didn't work", error.localizedDescription
                                                   + (shown ? " The part translated so far stays loaded." : "")))
        remove(id)
      } else {
        update(id) { $0.status = .error; $0.error = error.localizedDescription; $0.retry = "" }
        save()
      }
    }
  }

  /// A finished translation: the video playing now has it on screen, a file from the queue also gets a copy next to
  /// the original, if that is switched on.
  private func finish(_ id: UUID, output: URL) {
    guard let job = job(id) else { return }
    if job.isLive {
      remove(id)
      return
    }
    var path = output.path
    if Preference.bool(for: .subTranslateSaveNextToOriginal), let original = job.videoPath ?? job.subtitlePath {
      let copy = Self.sidecarURL(for: URL(fileURLWithPath: original), lang: job.lang)
      do {
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: output, to: copy)
        path = copy.path
      } catch {
        Logger.log("Cannot save the translation next to \(original): \(error.localizedDescription)", level: .warning)
      }
    }
    update(id) { $0.status = .done; $0.outputPath = path; $0.retry = "" }
    save()
  }

  /// "Movie.cs.translated.srt" next to "Movie.mkv" (or "Movie.en.srt"): its own name, so a subtitle file that was
  /// already there is never overwritten, and a later translation replaces the earlier one.
  nonisolated static func sidecarURL(for original: URL, lang: String) -> URL {
    var base = original.deletingPathExtension()
    let suffix = base.pathExtension.lowercased()
    if !suffix.isEmpty && (ISO639Helper.dictionary[suffix] != nil || SubtitleTranslator.languages.contains { $0.code.lowercased() == suffix }) {
      base = base.deletingPathExtension()
    }
    return base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent).\(lang).translated.srt")
  }

  /// Runs a request again after a temporary failure, waiting longer each time.
  nonisolated private static func retrying<T>(waits: [UInt64], onWait: (String) async -> Void,
                                              _ operation: () async throws -> T) async throws -> T {
    for seconds in waits {
      do {
        return try await operation()
      } catch let error as TranslationServiceError where error.isTemporary {
        await onWait("Didn't work, trying again in \(seconds) s: \(error.localizedDescription)")
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
      }
    }
    return try await operation()
  }

  // MARK: - Describing

  /// One line about where a job is, as the queue and the translate menu show it.
  static func note(for job: TranslationJob, paused: Bool) -> String {
    let count = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
    let lines = "\(count(job.linesDone)) / \(count(job.cues.count)) lines"
    switch job.status {
    case .done:
      return "Done · \(count(job.cues.count)) lines" + (job.model.isEmpty ? "" : " · \(job.model)")
    case .error:
      return "Stopped: \(job.error)"
    case .running:
      if !job.retry.isEmpty { return job.retry }
      if job.cues.isEmpty { return "Reading the subtitles…" }
      if job.chunks.isEmpty && job.linesDone == 0 && job.sheet == nil && !job.model.isEmpty {
        return "Reading the whole file first · \(job.model)"
      }
      return "Translating · \(lines)" + (job.model.isEmpty ? "" : " · \(job.model)")
    case .waiting:
      return (paused && !job.isLive ? "Paused" : "Waiting") + (job.linesDone > 0 ? " · \(lines)" : "")
    }
  }
}
