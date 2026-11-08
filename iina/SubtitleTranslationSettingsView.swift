//
//  SubtitleTranslationSettingsView.swift
//  iina
//
//  The "Translation" section of Settings > Subtitles: which service translates subtitles, its address, API key and
//  model, and where a translation is shown. Built in code so the nib stays as upstream has it.
//

import Cocoa

final class SubtitleTranslationSettingsView: NSView {

  private let enginePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let serverField = NSTextField(string: "")
  private let keyField = NSSecureTextField(string: "")
  private let modelComboBox = NSComboBox()
  private let refreshButton = NSButton()
  private let spinner = NSProgressIndicator()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let placementPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let googleHelpCheckbox = NSButton(checkboxWithTitle: "Let Google Translate help", target: nil, action: nil)
  private let queueButton = NSButton(title: "Translation Queue…", target: nil, action: nil)
  private let helpLabel = NSTextField(wrappingLabelWithString: "")
  private var grid: NSGridView!
  private var loadTask: Task<Void, Never>?

  private enum Row: Int { case engine, server, key, model, status, googleHelp, placement, queue }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
    translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "Translation:")
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    for engine in TranslationEngine.allCases {
      enginePopUp.addItem(withTitle: engine.title)
      enginePopUp.lastItem?.representedObject = engine.rawValue
    }
    enginePopUp.target = self
    enginePopUp.action = #selector(engineChanged)

    serverField.placeholderString = TranslationEngine.defaultLocalURL
    serverField.stringValue = Preference.string(for: .subTranslateLocalURL) ?? ""
    keyField.placeholderString = "Paste your API key"
    for field in [serverField, keyField, modelComboBox] as [NSTextField] {
      (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
      field.target = self
      field.lineBreakMode = .byTruncatingTail
    }
    serverField.action = #selector(serverChanged)
    keyField.action = #selector(keyChanged)
    modelComboBox.action = #selector(modelChanged)
    modelComboBox.completes = true
    modelComboBox.numberOfVisibleItems = 12

    refreshButton.image = NSImage(named: NSImage.refreshTemplateName)
    refreshButton.bezelStyle = .rounded
    refreshButton.toolTip = "Load the list of models"
    refreshButton.target = self
    refreshButton.action = #selector(refreshModels)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    let modelRow = NSStackView(views: [modelComboBox, refreshButton, spinner])
    modelRow.spacing = 6

    for placement in TranslationPlacement.allCases {
      placementPopUp.addItem(withTitle: placement.title)
      placementPopUp.lastItem?.representedObject = placement.rawValue
    }
    placementPopUp.target = self
    placementPopUp.action = #selector(placementChanged)

    googleHelpCheckbox.target = self
    googleHelpCheckbox.action = #selector(googleHelpChanged)
    googleHelpCheckbox.state = Preference.bool(for: .subTranslateGoogleHelp) ? .on : .off
    googleHelpCheckbox.toolTip = "Google's version shows over the video while the model works, and fills in lines the model leaves out. Turn off to keep everything on this Mac."
    queueButton.bezelStyle = .rounded
    queueButton.target = self
    queueButton.action = #selector(openQueue)

    for label in [statusLabel, helpLabel] {
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      label.textColor = .secondaryLabelColor
      label.preferredMaxLayoutWidth = 350
    }
    statusLabel.preferredMaxLayoutWidth = 240

    let engineLabel = Self.label("Translate with:")
    grid = NSGridView(views: [
      [engineLabel, enginePopUp],
      [Self.label("Server:"), serverField],
      [Self.label("API key:"), keyField],
      [Self.label("Model:"), modelRow],
      [NSGridCell.emptyContentView, statusLabel],
      [NSGridCell.emptyContentView, googleHelpCheckbox],
      [Self.label("Show translation:"), placementPopUp],
      [NSGridCell.emptyContentView, queueButton],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.rowAlignment = .firstBaseline
    grid.translatesAutoresizingMaskIntoConstraints = false

    for view in [title, grid!, helpLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: leadingAnchor),
      title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 120),
      grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      engineLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
      helpLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
      helpLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      helpLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
      helpLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      serverField.widthAnchor.constraint(equalToConstant: 230),
      keyField.widthAnchor.constraint(equalToConstant: 230),
      modelComboBox.widthAnchor.constraint(equalToConstant: 190),
    ])

    let engine = TranslationEngine.current
    enginePopUp.selectItem(at: TranslationEngine.allCases.firstIndex(of: engine) ?? 0)
    placementPopUp.selectItem(at: TranslationPlacement.allCases.firstIndex(of: .current) ?? 0)
    update(for: engine, loadModels: true)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func label(_ text: String) -> NSTextField {
    NSTextField(labelWithString: text)
  }

  private var engine: TranslationEngine {
    TranslationEngine(rawValue: enginePopUp.selectedItem?.representedObject as? String ?? "") ?? .google
  }

  // MARK: - Actions

  @objc private func engineChanged() {
    TranslationEngine.current = engine
    update(for: engine, loadModels: true)
  }

  @objc private func serverChanged() {
    let value = serverField.stringValue.trimmingCharacters(in: .whitespaces)
    guard value != Preference.string(for: .subTranslateLocalURL) ?? "" else { return }
    Preference.set(value, for: .subTranslateLocalURL)
    refreshModels()
  }

  @objc private func keyChanged() {
    let engine = engine
    guard engine.needsKey, keyField.stringValue != engine.apiKey else { return }
    engine.apiKey = keyField.stringValue
    refreshModels()
  }

  @objc private func modelChanged() {
    guard engine.isLanguageModel, modelComboBox.stringValue != engine.model else { return }
    engine.model = modelComboBox.stringValue
  }

  @objc private func placementChanged() {
    let raw = placementPopUp.selectedItem?.representedObject as? String ?? ""
    TranslationPlacement.current = TranslationPlacement(rawValue: raw) ?? .primary
  }

  @objc private func googleHelpChanged() {
    Preference.set(googleHelpCheckbox.state == .on, for: .subTranslateGoogleHelp)
  }

  @objc private func openQueue() {
    TranslationQueueWindowController.shared.showWindow(self)
  }

  @objc private func refreshModels() {
    let engine = engine
    loadTask?.cancel()
    guard engine.isLanguageModel, !engine.needsKey || !engine.apiKey.isEmpty else {
      spinner.stopAnimation(nil)
      setStatus("")
      return
    }
    spinner.startAnimation(nil)
    setStatus("")
    loadTask = Task { [weak self] in
      let result: Result<[String], Error>
      do {
        result = .success(try await LanguageModelClient.listModels(engine))
      } catch {
        result = .failure(error)
      }
      await MainActor.run {
        guard let self, !Task.isCancelled, self.engine == engine else { return }
        self.spinner.stopAnimation(nil)
        switch result {
        case .success(let models):
          self.modelComboBox.removeAllItems()
          self.modelComboBox.addItems(withObjectValues: models)
          if models.isEmpty {
            self.setStatus(engine == .local
                           ? "Connected, but no model is installed. With Ollama, run \"ollama pull gemma3\" in Terminal."
                           : "Connected, but no models are available.")
          } else {
            self.setStatus("Connected. \(models.count) \(models.count == 1 ? "model" : "models") available.")
          }
        case .failure(let error):
          self.setStatus(error.localizedDescription, isError: true)
        }
      }
    }
  }

  // MARK: - Updating

  private func update(for engine: TranslationEngine, loadModels: Bool) {
    grid.row(at: Row.server.rawValue).isHidden = engine != .local
    grid.row(at: Row.key.rawValue).isHidden = !engine.needsKey
    grid.row(at: Row.model.rawValue).isHidden = !engine.isLanguageModel
    grid.row(at: Row.googleHelp.rawValue).isHidden = !engine.isLanguageModel
    keyField.stringValue = engine.needsKey ? engine.apiKey : ""
    modelComboBox.removeAllItems()
    modelComboBox.stringValue = engine.model
    modelComboBox.placeholderString = "Automatic"
    helpLabel.stringValue = help(for: engine)
    setStatus("")
    if loadModels { refreshModels() }
  }

  private func setStatus(_ text: String, isError: Bool = false) {
    statusLabel.stringValue = text
    statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    grid.row(at: Row.status.rawValue).isHidden = text.isEmpty
  }

  private func help(for engine: TranslationEngine) -> String {
    guard engine == .local else { return engine.help }
    return engine.help + " Ollama's address is http://localhost:11434/v1, LM Studio's http://localhost:1234/v1."
  }
}
