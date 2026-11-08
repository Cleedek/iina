//
//  SubtitleTranslationEngine.swift
//  iina
//
//  The services that can translate subtitles (Google Translate, a local model served by Ollama or LM Studio, or a cloud
//  model from Google, Anthropic or OpenAI) and how a batch of subtitles is sent to a language model.
//

import Foundation

enum TranslationEngine: String, CaseIterable {
  case google, local, gemini, anthropic, openai

  static var current: TranslationEngine {
    get { TranslationEngine(rawValue: Preference.string(for: .subTranslateEngine) ?? "") ?? .google }
    set { Preference.set(newValue.rawValue, for: .subTranslateEngine) }
  }

  var title: String {
    switch self {
    case .google: return "Google Translate"
    case .local: return "Local model (Ollama, LM Studio)"
    case .gemini: return "Google Gemini"
    case .anthropic: return "Anthropic Claude"
    case .openai: return "OpenAI"
    }
  }

  /// The name on the translator switch in the queue window.
  var shortTitle: String {
    switch self {
    case .google: return "Google"
    case .local: return "Local"
    case .gemini: return "Gemini"
    case .anthropic: return "Claude"
    case .openai: return "OpenAI"
    }
  }

  /// What the translator is like and what it needs.
  var help: String {
    switch self {
    case .google:
      return "Free and fast, nothing to set up. Each line is translated on its own, so the wording can be stiff."
    case .local:
      return "A model on this Mac, such as Gemma 3 in Ollama or LM Studio: free and private, but slower. A film takes a while; it reads the whole film first to work out who is who, then translates 30 lines at a time."
    case .gemini:
      return "Translates with the whole scene in mind. Uses your API key from Google AI Studio (aistudio.google.com), which has a free tier."
    case .anthropic:
      return "Translates with the whole scene in mind. Uses your API key from the Claude Console (console.anthropic.com), billed to that account. A Claude.ai subscription doesn't include API use."
    case .openai:
      return "Translates with the whole scene in mind. Uses your API key from platform.openai.com, billed to that account. A ChatGPT or Codex subscription doesn't include API use."
    }
  }

  /// The name used in sentences, as in "\(name) didn't accept the API key".
  var name: String {
    switch self {
    case .google: return "Google Translate"
    case .local: return "The local model"
    case .gemini: return "Gemini"
    case .anthropic: return "Claude"
    case .openai: return "OpenAI"
    }
  }

  var isLanguageModel: Bool { self != .google }
  var needsKey: Bool { self == .gemini || self == .anthropic || self == .openai }

  static let defaultLocalURL = "http://localhost:11434/v1"

  /// The API address up to, not including, /chat/completions (or /messages for Anthropic).
  var baseURL: String {
    switch self {
    case .google: return ""
    case .local:
      let url = (Preference.string(for: .subTranslateLocalURL) ?? "").trimmingCharacters(in: .whitespaces)
      return (url.isEmpty ? Self.defaultLocalURL : url).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
    case .anthropic: return "https://api.anthropic.com/v1"
    case .openai: return "https://api.openai.com/v1"
    }
  }

  /// The chosen model. Empty means automatic for the local engine and not chosen yet for the others.
  var model: String {
    get { (Preference.dictionary(for: .subTranslateModels)?[rawValue] as? String) ?? "" }
    nonmutating set {
      var all = Preference.dictionary(for: .subTranslateModels) ?? [:]
      all[rawValue] = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      Preference.set(all, for: .subTranslateModels)
    }
  }

  /// API keys live in the keychain, one item per engine.
  var apiKey: String {
    get { Keychain.read(service: keychainService) ?? "" }
    nonmutating set { Keychain.write(newValue.trimmingCharacters(in: .whitespacesAndNewlines), service: keychainService) }
  }

  private var keychainService: String { "IINA Subtitle Translation API Key (\(rawValue))" }

  /// Requests at a time. A local model works on one request at a time anyway, and the free Gemini tier allows only a
  /// few a minute.
  var concurrency: Int {
    switch self {
    case .google: return 2
    case .local: return 1
    default: return 2
    }
  }

  var requestTimeout: TimeInterval {
    // A local model may first need to load into memory, and a slow Mac takes a while for a chunk.
    self == .local ? 300 : 120
  }
}

/// Where a finished translation goes.
enum TranslationPlacement: String, CaseIterable {
  /// The translation becomes the primary subtitle. If the original was the primary subtitle, it moves to secondary.
  case primary
  /// The translation becomes the secondary subtitle. The primary subtitle stays as it is.
  case secondary
  /// The translation takes the original's place, primary or secondary.
  case replace

  static var current: TranslationPlacement {
    get { TranslationPlacement(rawValue: Preference.string(for: .subTranslatePlacement) ?? "") ?? .primary }
    set { Preference.set(newValue.rawValue, for: .subTranslatePlacement) }
  }

  var title: String {
    switch self {
    case .primary: return "As primary, original as secondary"
    case .secondary: return "As secondary subtitles"
    case .replace: return "In place of the original"
    }
  }
}

/// An error from a translation service. Temporary ones (server trouble, dropped connections) are tried again.
struct TranslationServiceError: LocalizedError {
  let errorDescription: String?
  let isTemporary: Bool
  init(_ message: String, temporary: Bool = false) {
    errorDescription = message
    isTemporary = temporary
  }
}

// MARK: - Talking to language models

/// Ollama, LM Studio, Gemini and OpenAI all speak the OpenAI chat completions API. Anthropic has its own Messages API.
/// The request details follow the Subtitle Overlay extension, where they were worked out against each service.
enum LanguageModelClient {

  private static let lock = NSLock()
  // What each model turned down once, so it isn't sent again: a temperature of its own (OpenAI's reasoning models),
  // a JSON schema for the answer (some local servers), or a reasoning level.
  private static var noTemperature = Set<String>()
  private static var noSchema = Set<String>()
  // Thinking only slows translation down. Some models can turn it off ("none"), others only turn it down ("minimal"),
  // older ones take no level at all: each model's lowest accepted level is found once ("" = don't send one).
  private static let efforts = ["none", "minimal", "low"]
  private static var effortOf: [String: String] = [:]

  private static func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  static func listModels(_ engine: TranslationEngine) async throws -> [String] {
    var request = try makeRequest(engine, path: engine == .anthropic ? "/models?limit=100" : "/models")
    request.timeoutInterval = 15
    let reply = try await send(request, engine: engine)
    guard reply.status == 200 else { throw failure(engine, reply) }
    guard let data = (reply.json as? [String: Any])?["data"] as? [[String: Any]] else {
      throw TranslationServiceError("\(engine.name) sent back an unexpected model list.")
    }
    let ids = data.compactMap { $0["id"] as? String }.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
    return ids.filter { id in
      switch engine {
      // Gemini and OpenAI also list image, speech and embedding models; only text chat ones can translate.
      case .gemini:
        return id.range(of: "^(gemini|gemma)", options: .regularExpression) != nil
          && id.range(of: "image|tts|audio|live|embed|vision|video|omni|transcribe|robotics", options: .regularExpression) == nil
      // No dated copies of the same model, no Pro (Responses API only, and costly).
      case .openai:
        return id.hasPrefix("gpt-")
          && id.range(of: #"image|tts|audio|realtime|live|transcribe|whisper|search|codex|cyber|oss|instruct|-pro\b|\d{4}-\d\d-\d\d"#,
                      options: .regularExpression) == nil
      default:
        return id.range(of: "embed", options: [.regularExpression, .caseInsensitive]) == nil
      }
    }.sorted()
  }

  /// The model to use when none is chosen: the newest Flash for Gemini, the newest Sonnet for Claude, a Gemma model
  /// for a local server, otherwise the first one listed.
  static func pickModel(_ engine: TranslationEngine, from models: [String]) -> String? {
    func newest(_ pattern: String, not: String? = nil) -> String? {
      models.filter { $0.range(of: pattern, options: .regularExpression) != nil
        && (not == nil || $0.range(of: not!, options: .regularExpression) == nil) }.sorted().last
    }
    // By version number, not by name: a name without a version ("gemini-flash-latest") only wins when it's alone.
    func version(_ model: String) -> [Double] {
      guard let range = model.range(of: #"-(\d+(?:\.\d+)?)-"#, options: .regularExpression) else { return [0] }
      return model[range].trimmingCharacters(in: CharacterSet(charactersIn: "-")).split(separator: ".").compactMap { Double($0) }
    }
    switch engine {
    case .gemini:
      let flash = models.filter { $0.contains("flash") && $0.range(of: "lite|preview|exp|thinking", options: .regularExpression) == nil }
      if let best = flash.max(by: { version($0).lexicographicallyPrecedes(version($1)) }) { return best }
    case .anthropic:
      if let best = newest("sonnet") { return best }
    case .openai:
      if let best = newest("terra") ?? newest("luna") { return best }
    case .local:
      if let best = models.first(where: { $0.lowercased().contains("gemma") }) { return best }
    case .google:
      return nil
    }
    return models.first
  }

  /// The chosen model, or the one `pickModel` picks from the service's list.
  static func resolveModel(_ engine: TranslationEngine) async throws -> String {
    let chosen = engine.model
    if !chosen.isEmpty { return chosen }
    let models = try await listModels(engine)
    guard let model = pickModel(engine, from: models) else {
      throw TranslationServiceError(engine == .local
        ? "No model is installed at \(engine.baseURL). With Ollama, run \"ollama pull gemma3:12b\" in Terminal."
        : "\(engine.name) lists no model that can translate.")
    }
    return model
  }

  /// Sends one chat request and returns the answer's text. With `schemaKeys`, servers that support it are held to a
  /// JSON answer with those keys, each `{"src", "tr"}`.
  static func chat(_ engine: TranslationEngine, model: String, system: String, user: String,
                   schemaKeys: [String]? = nil) async throws -> String {
    var temperature: Double? = locked { noTemperature.contains(model) } ? nil : 0.2
    var useSchema = schemaKeys != nil && engine != .anthropic && !locked { noSchema.contains(model) }
    var effort: String? = engine == .gemini || engine == .openai ? locked { effortOf[model] } ?? efforts[0] : nil
    if effort == "" { effort = nil }

    for attempt in 0... {
      var request: URLRequest
      var body: [String: Any] = ["model": model]
      if engine == .anthropic {
        request = try makeRequest(engine, path: "/messages")
        body["max_tokens"] = 8192
        body["system"] = system
        body["messages"] = [["role": "user", "content": user]]
      } else {
        request = try makeRequest(engine, path: "/chat/completions")
        body["stream"] = false
        body["messages"] = [["role": "system", "content": system], ["role": "user", "content": user]]
        // A small local model that starts repeating itself stops here.
        if engine == .local { body["max_tokens"] = 4096 }
      }
      if let temperature { body["temperature"] = temperature }
      if let effort { body["reasoning_effort"] = effort }
      if useSchema, let keys = schemaKeys {
        let line: [String: Any] = ["type": "object", "properties": ["src": ["type": "string"], "tr": ["type": "string"]],
                                   "required": ["src", "tr"], "additionalProperties": false]
        body["response_format"] = ["type": "json_schema", "json_schema": [
          "name": "subtitles", "strict": true,
          "schema": ["type": "object", "required": keys, "additionalProperties": false,
                     "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, line) })] as [String: Any],
        ] as [String: Any]]
      }
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      // Sorted, so the schema lists L01, L02, … in order: servers like Ollama make the model write the lines in the
      // schema's order, and a shuffled order makes it put translations under the wrong lines.
      request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      request.timeoutInterval = engine.requestTimeout

      let reply = try await send(request, engine: engine)
      if reply.status == 200 {
        let json = reply.json as? [String: Any]
        let text: String?
        if engine == .anthropic {
          text = (json?["content"] as? [[String: Any]])?
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        } else {
          text = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text else { throw TranslationServiceError("\(engine.name) sent back an unexpected answer.") }
        // Reasoning models served locally may include their thinking in the answer.
        return text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
      }

      let said = reply.message
      // The free Gemini tier allows only a few requests a minute: wait and try again. "limit: 0" means this model has
      // no free requests at all. Claude answers 529 when it's overloaded. OpenAI's 429 also means an account with no
      // credit left ("billing"): waiting won't help.
      if (reply.status == 429 || reply.status == 529) && attempt < 4 && !said.contains("limit: 0")
          && !(engine == .openai && said.range(of: "billing", options: .caseInsensitive) != nil) {
        try await Task.sleep(nanoseconds: UInt64(min(reply.retryAfter ?? 20, 60) * 1_000_000_000))
        continue
      }
      if reply.status == 400, let current = effort,
         said.range(of: "reasoning|thinking|effort|budget", options: [.regularExpression, .caseInsensitive]) != nil {
        let next = efforts.firstIndex(of: current).flatMap { $0 + 1 < efforts.count ? efforts[$0 + 1] : nil } ?? ""
        locked { effortOf[model] = next }
        effort = next.isEmpty ? nil : next
        continue
      }
      if reply.status == 400, temperature != nil, said.range(of: "temperature", options: .caseInsensitive) != nil {
        _ = locked { noTemperature.insert(model) }
        temperature = nil
        continue
      }
      if reply.status == 400, useSchema,
         said.range(of: "response_format|schema|structured", options: [.regularExpression, .caseInsensitive]) != nil {
        _ = locked { noSchema.insert(model) }
        useSchema = false
        continue
      }
      throw failure(engine, reply)
    }
    fatalError("unreachable")
  }

  private static func makeRequest(_ engine: TranslationEngine, path: String) throws -> URLRequest {
    guard let url = URL(string: engine.baseURL + path), url.scheme?.hasPrefix("http") == true else {
      throw TranslationServiceError("The server address \"\(engine.baseURL)\" isn't a valid web address.")
    }
    var request = URLRequest(url: url)
    let key = engine.apiKey
    if engine.needsKey && key.isEmpty {
      throw TranslationServiceError("Add your \(engine.name) API key in Settings > Subtitles > Translation.")
    }
    if engine == .anthropic {
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    } else if !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private struct Reply {
    let status: Int
    let json: Any?
    /// What the server said went wrong, or the standard text for the status.
    let message: String
    let retryAfter: Double?
  }

  private static func send(_ request: URLRequest, engine: TranslationEngine) async throws -> Reply {
    let data: Data, response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      let code = (error as? URLError)?.code
      if code == .cancelled || Task.isCancelled { throw CancellationError() }
      if engine == .local && (code == .cannotConnectToHost || code == .cannotFindHost) {
        throw TranslationServiceError("Can't reach the local model at \(engine.baseURL). Is Ollama or LM Studio running?")
      }
      if code == .timedOut {
        throw TranslationServiceError("\(engine.name) took too long to answer.", temporary: true)
      }
      throw TranslationServiceError("\(engine.name) could not be reached: \(error.localizedDescription)", temporary: true)
    }
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    let json = try? JSONSerialization.jsonObject(with: data)
    // Error bodies: {"error": {"message": "…"}} (OpenAI, Gemini, Anthropic, LM Studio) or {"error": "…"} (Ollama).
    let dict = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
    let error = dict?["error"]
    let said = ((error as? [String: Any])?["message"] as? String) ?? (error as? String)
    let message = String((said ?? HTTPURLResponse.localizedString(forStatusCode: status)).prefix(300))
    let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
    return Reply(status: status, json: json, message: message, retryAfter: retryAfter)
  }

  private static func failure(_ engine: TranslationEngine, _ reply: Reply) -> TranslationServiceError {
    let said = reply.message
    switch reply.status {
    case 401, 403:
      return TranslationServiceError("\(engine.name) didn't accept the API key. \(said)")
    case 429 where engine == .gemini:
      return TranslationServiceError("The free Gemini limit is used up for now. Try again later. \(said)")
    case 429, 529:
      return TranslationServiceError("\(engine.name) is busy or the limit is used up for now. Try again later. \(said)")
    case 500...599:
      return TranslationServiceError("\(engine.name) had a problem (HTTP \(reply.status)). \(said)", temporary: true)
    default:
      return TranslationServiceError("\(engine.name) answered HTTP \(reply.status). \(said)")
    }
  }
}

// MARK: - Translating subtitles with a language model

/// How subtitles are put to a language model, as in the Subtitle Overlay extension. Lines travel as HTML (<i>, <b>,
/// <br> for line breaks).
enum LanguageModelTranslator {

  static let chunkLines = 30
  static let contextLines = 4

  private static func prompt(_ language: String, sheet: String) -> String {
    var lines = ["You translate film and TV subtitles into \(language)."]
    if !sheet.isEmpty {
      lines += [
        "Notes on who is who, made earlier from the whole subtitle file (they can be incomplete, and the lines themselves win if they disagree):",
        "\"\"\"\n\(sheet)\n\"\"\"",
        "Use the notes to work out who is probably speaking to whom, then pick gender, forms of address and name spellings that fit, the same way throughout.",
      ]
    }
    lines += [
      "You get JSON: \"lines\", numbered subtitle lines to translate, and sometimes \"before\", the lines just before them, for context only.",
      "Answer with JSON only: the same numbers, each with \"src\", that line copied exactly, and \"tr\", the translation of that one line.",
      "A line is often only part of a sentence that goes on in the next line: translate it as that part, so the lines read naturally one after another, and never move words to another number.",
      "Keep <i>, <b>, <u> tags and <br> line breaks where they belong.",
      "Write natural, spoken \(language) that fits a subtitle: keep names, keep the tone (slang, swearing, formal or informal address) consistent with the context.",
    ]
    return lines.joined(separator: "\n")
  }

  /// "L01": numbered keys that sort in order.
  private static func key(_ i: Int) -> String { String(format: "L%02d", i + 1) }

  /// Letters and digits only, lowercased, to check that the model's copy of a line is that line.
  private static func bare(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]*>|&#?\\w+;", with: "", options: .regularExpression)
      .unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
      .map(String.init).joined().lowercased()
  }

  /// Translates one chunk of lines. A line the model left out comes back as "" (the caller keeps another version).
  ///
  /// Subtitle lines are often halves of a sentence, and a model given a plain list merges them. So lines go numbered,
  /// a JSON schema holds the server to the same numbers, and each answer first copies its line: a copy that doesn't
  /// match shows the translation drifted to another line, and that line is left out.
  static func translate(_ lines: [String], before: [String], sheet: String, to language: String,
                        engine: TranslationEngine, model: String) async throws -> [String] {
    func ask(_ lines: [String], before: [String]) async throws -> [String]? {
      let keys = lines.indices.map(key)
      var payload: [String: Any] = ["lines": Dictionary(uniqueKeysWithValues: zip(keys, lines))]
      if !before.isEmpty { payload["before"] = before }
      let user = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
      let text = try await LanguageModelClient.chat(engine, model: model, system: prompt(language, sheet: sheet),
                                                    user: user, schemaKeys: keys)
      guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
            var answer = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any] else {
        return nil
      }
      if let inner = answer["lines"] as? [String: Any] { answer = inner }
      return keys.enumerated().map { i, key in
        let value = answer[key]
        if let pair = value as? [String: Any] {
          guard let src = pair["src"] as? String, bare(src) == bare(lines[i]) else { return "" }
          return (pair["tr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    // The whole chunk a second time only when many lines are missing: a local model takes half a minute for it.
    var best: [String] = []
    let filled = { (texts: [String]) in texts.filter { !$0.isEmpty }.count }
    for _ in 0..<2 where Double(filled(best)) < Double(lines.count) * 0.8 {
      if let texts = try await ask(lines, before: before), filled(texts) > filled(best) { best = texts }
    }
    guard filled(best) > 0 else { throw TranslationServiceError("\(model) didn't send back the translated lines.") }
    // A few lines left out: one short request for just those. A line with no words in it (♪, …) isn't worth one.
    let missing = lines.indices.filter { best[$0].isEmpty && !bare(lines[$0]).isEmpty }
    if let first = missing.first {
      let again = try? await ask(missing.map { lines[$0] }, before: Array(lines[max(0, first - contextLines)..<first]))
      if Task.isCancelled { throw CancellationError() }
      if let again { for (n, i) in missing.enumerated() where !again[n].isEmpty { best[i] = again[n] } }
    }
    return best
  }

  // MARK: Notes on who is who

  /// A chunk of 30 lines can't tell who is who, and many languages need to know: Vietnamese pronouns depend on the
  /// age and relationship of the two people, Czech marks gender in the past tense. So the model first reads the whole
  /// file once and writes short notes that go along with every chunk. Returns "" when they can't be made:
  /// translation works without them.
  static func sheet(_ texts: [String], to language: String, engine: TranslationEngine, model: String) async throws -> String {
    let lines = texts.map {
      $0.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard lines.count >= 2 else { return "" }
    let system = [
      "Below are all the subtitle lines of a film or TV episode, in order. They will be translated into \(language) in small chunks, by someone who sees only these notes and the chunk.",
      "Write the notes, in English, plain text, at most 300 words:",
      "PEOPLE: each named character: gender, rough age, role, relationship to the others.",
      "ADDRESS: for each pair who talk to each other, the exact \(language) words: what A calls B, and what A calls themself when talking to B, then the same for B. The lines are in another language and won't show these words: choose them yourself from the two people's ages and relationship, as \(language) speakers normally would. Not just \"formal\" or \"informal\". Add what changes if their relationship changes during the story. Skip this only if \(language) has no such distinctions.",
      "NAMES: names of people, places and things that must stay spelled the same.",
      "Under PEOPLE, write only what the lines support, and \"unknown\" where they don't say. Start directly with PEOPLE, no introduction.",
    ].joined(separator: "\n")
    // A local model usually can't hold a whole film at once and would quietly lose the beginning: it gets evenly
    // spread parts instead.
    let user = sheetSource(lines, maxChars: engine == .local ? 12_000 : 200_000)
    do {
      let notes = try await LanguageModelClient.chat(engine, model: model, system: system, user: user)
      return String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      Logger.log("Notes for the subtitle translation couldn't be made: \(error.localizedDescription)", level: .warning)
      return ""
    }
  }

  private static func sheetSource(_ lines: [String], maxChars: Int) -> String {
    let text = lines.joined(separator: "\n")
    guard text.count > maxChars else { return text }
    let parts = 8, each = lines.count / parts, room = maxChars / parts
    return (0..<parts).map { p in
      String(lines[(p * each)..<((p + 1) * each)].joined(separator: "\n").prefix(room))
    }.joined(separator: "\n[...]\n")
  }
}

// MARK: - Keychain

/// Generic password items, one per service name.
private enum Keychain {
  static func read(service: String) -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnData as String: true]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Saves the value, or removes the item when the value is empty.
  static func write(_ value: String, service: String) {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    SecItemDelete(query as CFDictionary)
    guard !value.isEmpty else { return }
    var item = query
    item[kSecAttrLabel as String] = service
    item[kSecAttrAccount as String] = "IINA"
    item[kSecValueData as String] = Data(value.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess {
      Logger.log("Cannot save the API key in the keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")",
                 level: .error)
    }
  }
}
