//
//  SubtitleTranslator.swift
//  iina
//
//  Reads, translates with Google, writes and shows subtitle tracks. The translations themselves run in the
//  TranslationQueue, with Google Translate or a language model (see SubtitleTranslationEngine.swift).
//

import Foundation
import CryptoKit

class SubtitleTranslator {

  /// Google Translate codes and names, in the order the language menu shows them.
  static let languages: [(code: String, name: String)] = [
    ("cs", "Czech"), ("vi", "Vietnamese"), ("en", "English"), ("sk", "Slovak"), ("de", "German"),
    ("fr", "French"), ("es", "Spanish"), ("it", "Italian"), ("pt", "Portuguese"), ("pl", "Polish"),
    ("hu", "Hungarian"), ("uk", "Ukrainian"), ("ru", "Russian"), ("nl", "Dutch"), ("sv", "Swedish"),
    ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("el", "Greek"), ("tr", "Turkish"),
    ("ro", "Romanian"), ("hr", "Croatian"), ("zh-CN", "Chinese (Simplified)"),
    ("zh-TW", "Chinese (Traditional)"), ("ja", "Japanese"), ("ko", "Korean"), ("th", "Thai"),
    ("id", "Indonesian"), ("hi", "Hindi"), ("ar", "Arabic"), ("he", "Hebrew"),
  ]

  static func languageName(_ code: String) -> String {
    languages.first { $0.code == code }?.name ?? code
  }

  /// The remembered target language. The first time, the system language if it is in the list.
  static var targetLanguage: String {
    get {
      if let code = Preference.string(for: .subTranslateLang), !code.isEmpty { return code }
      let system = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
      return languages.contains { $0.code == system } ? system : "en"
    }
    set { Preference.set(newValue, for: .subTranslateLang) }
  }

  static let cacheDirURL: URL = {
    let url = Utility.cacheURL.appendingPathComponent("translated-subs", isDirectory: true)
    Utility.createDirIfNotExist(url: url)
    return url
  }()

  /// Translations made here: in the cache, or saved next to a video by the queue ("Movie.cs.translated.srt").
  static func isTranslation(_ track: MPVTrack) -> Bool {
    guard let file = track.externalFilename else { return false }
    return file.hasPrefix(cacheDirURL.path) || file.hasSuffix(".translated.srt")
  }

  /// The track to translate: the primary subtitle, otherwise the secondary one. Translations made here are skipped, so
  /// switching to another language always starts from the original text.
  static func sourceTrack(for player: PlayerCore) -> MPVTrack? {
    [player.info.currentTrack(.sub), player.info.currentTrack(.secondSub)]
      .compactMap { $0 }
      .first { $0.id != 0 && !$0.isImage && !isTranslation($0) }
  }

  struct Cue: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
  }

  struct TranslationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  // MARK: - Translating

  /// Translates the primary (or secondary) subtitle track of the video playing now. The translation queue does the
  /// work, before anything else in it, and shows the translation where the placement setting says.
  @MainActor
  static func translate(player: PlayerCore, to lang: String) {
    targetLanguage = lang
    guard let track = sourceTrack(for: player), let videoURL = player.info.currentURL else {
      player.sendOSD(.customWithDetail("Nothing to translate", "Choose a text subtitle track first."))
      return
    }
    TranslationQueue.shared.translateLive(player: player, track: track, videoURL: videoURL, lang: lang)
  }

  /// Where an embedded track is among the video's subtitle streams, counted the way FFmpeg reads them.
  static func streamOrdinal(of track: MPVTrack, in player: PlayerCore) -> Int {
    player.info.subTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }.firstIndex(of: track) ?? 0
  }

  /// The source of a translation as the cache knows it: the video, and the subtitle file or the stream's place inside
  /// the video. The queue and the player name a source the same way, so each finds the other's translation. (mpv's
  /// track ids and languages can't be used: FFmpeg, which the queue reads files with, numbers and names them otherwise.)
  static func sourceKey(video: URL, subtitleFile: String?, streamOrdinal: Int) -> String {
    let file = subtitleFile.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    return "\(video.resolvingSymlinksInPath().absoluteString)|\(file ?? "#s\(streamOrdinal)")"
  }

  /// One file per source, language and translator, so the same translation is never requested twice.
  static func outputURL(sourceKey: String, video: URL, lang: String, engine: TranslationEngine, model: String) -> URL {
    let key = "\(sourceKey)|\(engine.rawValue)|\(model)"
    let hash = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    let name = video.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "_")
    return cacheDirURL.appendingPathComponent("\(name).\(hash).\(lang).srt")
  }

  /// "Czech (gemma3:12b)", the name the translated track gets in the subtitle list.
  static func trackTitle(lang: String, model: String) -> String {
    "\(languageName(lang)) (\(model.isEmpty ? "translated" : model))"
  }

  // MARK: - Showing

  /// Loads the translation (or reloads it, if an older version is loaded) and puts it where `placement` says.
  static func show(_ url: URL, title: String, lang: String, player: PlayerCore, source: MPVTrack?,
                   placement: TranslationPlacement) {
    let sourceWasPrimary = source != nil && source?.id == player.info.sid
    let sourceWasSecondary = source != nil && source?.id == player.info.secondSid
    guard let id = reload(url, title: title, lang: lang, player: player)
            ?? add(url, title: title, lang: lang, player: player) else { return }
    let asPrimary: Bool
    switch placement {
    case .primary: asPrimary = true
    case .secondary: asPrimary = false
    case .replace: asPrimary = !sourceWasSecondary
    }
    // mpv refuses a track that is already selected in the other slot.
    if asPrimary {
      if player.info.secondSid == id { player.setTrack(0, forType: .secondSub) }
      player.setTrack(id, forType: .sub)
      if placement == .primary && sourceWasPrimary, let source { player.setTrack(source.id, forType: .secondSub) }
      player.toggleSubVisibility(true)
    } else {
      if player.info.sid == id { player.setTrack(0, forType: .sub) }
      player.setTrack(id, forType: .secondSub)
      player.toggleSecondSubVisibility(true)
    }
  }

  /// Loads the file again after it changed and keeps the new track where the old one was: primary, secondary or off.
  /// Returns the new track, or nil if the file wasn't loaded.
  @discardableResult
  static func reload(_ url: URL, title: String, lang: String, player: PlayerCore) -> Int? {
    guard let old = player.info.subTracks.last(where: { $0.externalFilename == url.path }) else { return nil }
    let wasPrimary = old.id == player.info.sid
    let wasSecondary = old.id == player.info.secondSid
    guard let new = add(url, title: title, lang: lang, player: player), new != old.id else { return old.id }
    if wasPrimary { player.setTrack(new, forType: .sub) }
    if wasSecondary { player.setTrack(new, forType: .secondSub) }
    player.mpv.command(.subRemove, args: [String(old.id)], checkError: false)
    player.getTrackInfo()
    player.getSelectedTracks()
    return new
  }

  /// Adds the file as a subtitle track without selecting it and returns the new track.
  private static func add(_ url: URL, title: String, lang: String, player: PlayerCore) -> Int? {
    var added = false
    player.mpv.command(.subAdd, args: [url.path, "auto", title, lang], checkError: false) { added = $0 >= 0 }
    guard added else {
      player.log("Cannot load translated subtitles: \(url.path)", level: .error)
      return nil
    }
    player.getTrackInfo()
    return player.info.subTracks.filter { $0.externalFilename == url.path }.map(\.id).max()
  }

  // MARK: - Reading

  static func readCues(track: MPVTrack, videoURL: URL, ordinal: Int, encoding: String?) throws -> [Cue] {
    if let external = track.externalFilename {
      guard FileManager.default.fileExists(atPath: external) else {
        throw TranslationError("Only subtitles from a file on this Mac can be translated.")
      }
      return try readCues(file: external, ordinal: 0, external: true, encoding: encoding)
    }
    guard videoURL.isFileURL else {
      throw TranslationError("Subtitles inside an online stream cannot be translated yet.")
    }
    return try readCues(file: videoURL.path, ordinal: ordinal, external: false, encoding: encoding)
  }

  /// Reads the text subtitles of a subtitle file (`external`), or the subtitle stream at `ordinal` inside a video.
  static func readCues(file: String, ordinal: Int, external: Bool, encoding: String?) throws -> [Cue] {
    let charEncoding = external ? try detectEncoding(of: URL(fileURLWithPath: file), preferred: encoding) : nil
    let raw = try FFmpegController.readTextSubtitles(fromFile: file, streamOrdinal: ordinal,
                                                     charEncoding: charEncoding, subtractStartTime: !external)
    var cues: [Cue] = raw.compactMap { dict in
      guard let start = dict["start"] as? Double, let end = dict["end"] as? Double,
            let text = dict["text"] as? String else { return nil }
      let clean = cleanAss(text)
      return clean.isEmpty ? nil : Cue(start: start, end: end, text: clean)
    }
    cues.sort { $0.start < $1.start }
    // A cue without a known end lasts until the next one, at most 5 seconds.
    for i in cues.indices where cues[i].end <= cues[i].start {
      let next = i + 1 < cues.count ? cues[i + 1].start : cues[i].start + 5
      cues[i].end = min(next, cues[i].start + 5)
    }
    guard !cues.isEmpty else { throw TranslationError("The subtitle track has no text.") }
    return cues
  }

  /// FFmpeg reads files as UTF-8. Other files (for example Czech SRT in Windows-1250) need their encoding named.
  private static func detectEncoding(of url: URL, preferred: String?) throws -> String? {
    let data = try Data(contentsOf: url)
    if String(data: data, encoding: .utf8) != nil { return nil }
    if let preferred, preferred != "auto" { return preferred }
    var converted: NSString?
    let guessed = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
    guard guessed != 0,
          let name = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(guessed)) else {
      return nil
    }
    return name as String
  }

  /// The decoders give ASS dialogue lines: "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text".
  /// Keeps the text with italics and bold as <i>/<b>, drops the other styling.
  static func cleanAss(_ dialogue: String) -> String {
    dialogue.split(separator: "\n").map { line -> String in
      var text = Substring(line)
      for _ in 0..<8 {
        guard let comma = text.firstIndex(of: ",") else { break }
        text = text[text.index(after: comma)...]
      }
      var s = String(text)
      for (tag, html) in [("\\i1", "<i>"), ("\\i0", "</i>"), ("\\b1", "<b>"), ("\\b0", "</b>")] {
        s = s.replacingOccurrences(of: "{\(tag)}", with: html)
      }
      s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
      s = s.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\h", with: " ")
      return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  // MARK: - Google Translate

  // Google Translate's free web endpoint (the one its own widgets use, no key). One `q` per subtitle comes back as one
  // result per subtitle, so the timing stays cue for cue. Text goes as HTML so <i>/<b> and line breaks survive.
  private static let googleURL = "https://translate.googleapis.com/translate_a/t?client=gtx&sl=auto&format=html&tl="

  private static let googleBatchChars = 4000
  private static let googleBatchLines = 120

  /// Translates lines (HTML) with Google, a few batches at a time: a whole film takes a few seconds.
  static func googleTranslateAll(_ lines: [String], to lang: String) async throws -> [String] {
    var batches: [Range<Int>] = []
    var start = 0, size = 0
    for (i, line) in lines.enumerated() {
      if i > start && (size + line.count > googleBatchChars || i - start >= googleBatchLines) {
        batches.append(start..<i)
        start = i
        size = 0
      }
      size += line.count
    }
    if start < lines.count { batches.append(start..<lines.count) }

    var results = [String](repeating: "", count: lines.count)
    // Two requests at a time: fast for a full film, gentle enough not to get blocked.
    try await withThrowingTaskGroup(of: (Range<Int>, [String]).self) { group in
      var next = 0
      while next < min(2, batches.count) {
        let range = batches[next]
        group.addTask { (range, try await googleTranslate(Array(lines[range]), to: lang)) }
        next += 1
      }
      while let (range, texts) = try await group.next() {
        for (k, text) in texts.enumerated() { results[range.lowerBound + k] = text }
        if next < batches.count {
          let range = batches[next]
          group.addTask { (range, try await googleTranslate(Array(lines[range]), to: lang)) }
          next += 1
        }
      }
    }
    return results
  }

  private static func googleTranslate(_ lines: [String], to lang: String) async throws -> [String] {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._*")
    let body = lines.map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
    var request = URLRequest(url: URL(string: googleURL + lang)!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body.utf8)
    request.timeoutInterval = 30

    let data: Data, response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      if (error as? URLError)?.code == .cancelled || Task.isCancelled { throw CancellationError() }
      throw TranslationServiceError("Google Translate could not be reached. Check the internet connection.", temporary: true)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 429 {
      throw TranslationServiceError("Google Translate says \"too many requests\". Wait a few minutes and try again.",
                                    temporary: true)
    }
    guard status == 200 else { throw TranslationError("Google Translate answered HTTP \(status).") }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
      throw TranslationError("Google Translate sent back something unexpected.")
    }
    // With sl=auto each result is [text, detected language]; a single line can come back bare as [text, language].
    if lines.count == 1, let text = json.first as? String { return [text] }
    let texts = json.compactMap { item -> String? in
      if let pair = item as? [Any] { return pair.first as? String }
      return item as? String
    }
    guard texts.count == lines.count else {
      throw TranslationError("Google Translate sent back something unexpected.")
    }
    return texts
  }

  static func toHtml(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    for tag in ["i", "b"] {
      s = s.replacingOccurrences(of: "&lt;\(tag)&gt;", with: "<\(tag)>")
        .replacingOccurrences(of: "&lt;/\(tag)&gt;", with: "</\(tag)>")
    }
    return s.replacingOccurrences(of: "\n", with: "<br>")
  }

  static func fromHtml(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "\\s*<br\\s*/?>\\s*", with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<(?!/?[ib]>)[^>]*>", with: "", options: .regularExpression)
    for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      s = s.replacingOccurrences(of: entity, with: char)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Writing

  static func writeSRT(_ cues: [Cue], to url: URL) throws {
    func time(_ seconds: Double) -> String {
      let ms = max(0, Int((seconds * 1000).rounded()))
      return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    let srt = cues.enumerated().map { i, cue in
      "\(i + 1)\n\(time(cue.start)) --> \(time(cue.end))\n\(cue.text)\n"
    }.joined(separator: "\n")
    try srt.write(to: url, atomically: true, encoding: .utf8)
  }
}
