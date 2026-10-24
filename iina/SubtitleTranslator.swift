//
//  SubtitleTranslator.swift
//  iina
//
//  Translates a text subtitle track with Google Translate and loads the result as a new track.
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

  static func isTranslation(_ track: MPVTrack) -> Bool {
    track.externalFilename?.hasPrefix(cacheDirURL.path) ?? false
  }

  /// The track to translate: the primary subtitle, otherwise the secondary one. Translations made here are skipped, so
  /// switching to another language always starts from the original text.
  static func sourceTrack(for player: PlayerCore) -> MPVTrack? {
    [player.info.currentTrack(.sub), player.info.currentTrack(.secondSub)]
      .compactMap { $0 }
      .first { $0.id != 0 && !$0.isImage && !isTranslation($0) }
  }

  struct Cue {
    var start: Double
    var end: Double
    var text: String
  }

  struct TranslationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  // MARK: - Translating

  /// Translates the primary (or secondary) subtitle track and shows the translation as the primary subtitle. The original
  /// becomes the secondary subtitle so it is still at hand.
  static func translate(player: PlayerCore, to lang: String) {
    targetLanguage = lang
    let langName = languageName(lang)
    guard let track = sourceTrack(for: player), let videoURL = player.info.currentURL else {
      player.sendOSD(.customWithDetail("Nothing to translate", "Choose a text subtitle track first."))
      return
    }
    let output = outputURL(video: videoURL, track: track, lang: lang)
    if FileManager.default.fileExists(atPath: output.path) {
      show(output, player: player, source: track, lang: lang)
      player.sendOSD(.custom("Subtitles translated to \(langName)"))
      return
    }

    player.sendOSD(.custom("Translating subtitles to \(langName)…"), autoHide: false)
    let ordinal = player.info.subTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }.firstIndex(of: track) ?? 0
    let encoding = player.info.subEncoding
    Task.detached {
      do {
        let cues = try readCues(track: track, videoURL: videoURL, ordinal: ordinal, encoding: encoding)
        let translated = try await translateTexts(cues.map { toHtml($0.text) }, to: lang)
        var result = cues
        for i in result.indices { result[i].text = fromHtml(translated[i]) }
        try writeSRT(result, to: output)
        await MainActor.run {
          guard player.info.currentURL == videoURL else { return }
          show(output, player: player, source: track, lang: lang)
          player.sendOSD(.custom("Subtitles translated to \(langName)"))
        }
      } catch {
        player.log("Subtitle translation failed: \(error.localizedDescription)", level: .error)
        await MainActor.run {
          player.sendOSD(.customWithDetail("Translation didn't work", error.localizedDescription))
        }
      }
    }
  }

  /// One file per video, source track and language, so the same translation is never requested twice.
  private static func outputURL(video: URL, track: MPVTrack, lang: String) -> URL {
    let key = "\(video.absoluteString)|\(track.externalFilename ?? "#\(track.srcId ?? track.id)")|\(track.lang ?? "")"
    let hash = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    let name = video.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "_")
    return cacheDirURL.appendingPathComponent("\(name).\(hash).\(lang).srt")
  }

  private static func show(_ url: URL, player: PlayerCore, source: MPVTrack, lang: String) {
    let wasPrimary = source.id == player.info.sid
    let loaded = player.info.subTracks.first { $0.externalFilename == url.path }
    if let loaded {
      player.setTrack(loaded.id, forType: .sub)
    } else {
      let title = "\(languageName(lang)) (translated)"
      player.mpv.command(.subAdd, args: [url.path, "select", title, lang], checkError: false) { code in
        if code < 0 { player.log("Cannot load translated subtitles: \(url.path)", level: .error) }
      }
    }
    if wasPrimary {
      player.setTrack(source.id, forType: .secondSub)
    }
    player.toggleSubVisibility(true)
    player.getSelectedTracks()
  }

  // MARK: - Reading

  private static func readCues(track: MPVTrack, videoURL: URL, ordinal: Int, encoding: String?) throws -> [Cue] {
    let path: String
    var charEncoding: String?
    if let external = track.externalFilename {
      guard FileManager.default.fileExists(atPath: external) else {
        throw TranslationError("Only subtitles from a file on this Mac can be translated.")
      }
      path = external
      charEncoding = try detectEncoding(of: URL(fileURLWithPath: external), preferred: encoding)
    } else {
      guard videoURL.isFileURL else {
        throw TranslationError("Subtitles inside an online stream cannot be translated yet.")
      }
      path = videoURL.path
    }
    let raw = try FFmpegController.readTextSubtitles(fromFile: path,
                                                     streamOrdinal: track.isExternal ? 0 : ordinal,
                                                     charEncoding: charEncoding,
                                                     subtractStartTime: !track.isExternal)
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
  private static let batchChars = 4000
  private static let batchLines = 120

  private static func translateTexts(_ texts: [String], to lang: String) async throws -> [String] {
    var batches: [[String]] = []
    var current: [String] = [], size = 0
    for text in texts {
      if !current.isEmpty && (size + text.count > batchChars || current.count >= batchLines) {
        batches.append(current)
        current = []
        size = 0
      }
      current.append(text)
      size += text.count
    }
    if !current.isEmpty { batches.append(current) }

    // Two requests at a time: fast for a full film, gentle enough not to get blocked.
    var results = [[String]](repeating: [], count: batches.count)
    try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
      var next = 0
      while next < min(2, batches.count) {
        let index = next
        group.addTask { (index, try await translateBatch(batches[index], to: lang)) }
        next += 1
      }
      while let (index, translated) = try await group.next() {
        results[index] = translated
        if next < batches.count {
          let index = next
          group.addTask { (index, try await translateBatch(batches[index], to: lang)) }
          next += 1
        }
      }
    }
    return results.flatMap { $0 }
  }

  private static func translateBatch(_ lines: [String], to lang: String) async throws -> [String] {
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
      throw TranslationError("Google Translate could not be reached. Check the internet connection.")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 429 {
      throw TranslationError("Google Translate says \"too many requests\". Wait a few minutes and try again.")
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

  private static func toHtml(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    for tag in ["i", "b"] {
      s = s.replacingOccurrences(of: "&lt;\(tag)&gt;", with: "<\(tag)>")
        .replacingOccurrences(of: "&lt;/\(tag)&gt;", with: "</\(tag)>")
    }
    return s.replacingOccurrences(of: "\n", with: "<br>")
  }

  private static func fromHtml(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "\\s*<br\\s*/?>\\s*", with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<(?!/?[ib]>)[^>]*>", with: "", options: .regularExpression)
    for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      s = s.replacingOccurrences(of: entity, with: char)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Writing

  private static func writeSRT(_ cues: [Cue], to url: URL) throws {
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
