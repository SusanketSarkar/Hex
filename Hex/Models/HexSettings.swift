import ComposableArchitecture
import Dependencies
import Foundation

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct HexSettings: Codable, Equatable {
	var soundEffectsEnabled: Bool = true
	var hotkey: HotKey = .init(key: nil, modifiers: [.option])
	var openOnLogin: Bool = false
	var showDockIcon: Bool = true
	var selectedModel: String = "openai_whisper-large-v3-v20240930"
	var useClipboardPaste: Bool = true
	var preventSystemSleep: Bool = true
	var pauseMediaOnRecord: Bool = true
	var minimumKeyTime: Double = 0.2
	var copyToClipboard: Bool = false
	var useDoubleTapOnly: Bool = false
	var outputLanguage: String? = nil
	var selectedMicrophoneID: String? = nil
	var saveTranscriptionHistory: Bool = true
	var maxHistoryEntries: Int? = nil
	
	// Ollama Settings
	var ollamaEnabled: Bool = false
	var ollamaModel: String = "llama3.2"
	var ollamaBaseURL: String = "http://localhost:11434"

	// Define coding keys to match struct properties
	enum CodingKeys: String, CodingKey {
		case soundEffectsEnabled
		case hotkey
		case openOnLogin
		case showDockIcon
		case selectedModel
		case useClipboardPaste
		case preventSystemSleep
		case pauseMediaOnRecord
		case minimumKeyTime
		case copyToClipboard
		case useDoubleTapOnly
		case outputLanguage
		case selectedMicrophoneID
		case saveTranscriptionHistory
		case maxHistoryEntries
		case ollamaEnabled
		case ollamaModel
		case ollamaBaseURL
	}

	init(
		soundEffectsEnabled: Bool = true,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = "openai_whisper-large-v3-v20240930",
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		pauseMediaOnRecord: Bool = true,
		minimumKeyTime: Double = 0.2,
		copyToClipboard: Bool = false,
		useDoubleTapOnly: Bool = false,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		ollamaEnabled: Bool = false,
		ollamaModel: String = "llama3.2",
		ollamaBaseURL: String = "http://localhost:11434"
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.pauseMediaOnRecord = pauseMediaOnRecord
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.useDoubleTapOnly = useDoubleTapOnly
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.ollamaEnabled = ollamaEnabled
		self.ollamaModel = ollamaModel
		self.ollamaBaseURL = ollamaBaseURL
	}

	// Custom decoder that handles missing fields
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		// Decode each property, using decodeIfPresent with default fallbacks
		soundEffectsEnabled =
			try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
		hotkey =
			try container.decodeIfPresent(HotKey.self, forKey: .hotkey)
				?? .init(key: nil, modifiers: [.option])
		openOnLogin = try container.decodeIfPresent(Bool.self, forKey: .openOnLogin) ?? false
		showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
		selectedModel =
			try container.decodeIfPresent(String.self, forKey: .selectedModel)
				?? "openai_whisper-large-v3-v20240930"
		useClipboardPaste = try container.decodeIfPresent(Bool.self, forKey: .useClipboardPaste) ?? true
		preventSystemSleep =
			try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true
		pauseMediaOnRecord =
			try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) ?? true
		minimumKeyTime =
			try container.decodeIfPresent(Double.self, forKey: .minimumKeyTime) ?? 0.2
		copyToClipboard =
			try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? false
		useDoubleTapOnly =
			try container.decodeIfPresent(Bool.self, forKey: .useDoubleTapOnly) ?? false
		outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
		selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
		saveTranscriptionHistory =
			try container.decodeIfPresent(Bool.self, forKey: .saveTranscriptionHistory) ?? true
		maxHistoryEntries = try container.decodeIfPresent(Int.self, forKey: .maxHistoryEntries)
		
		// Ollama settings
		ollamaEnabled = try container.decodeIfPresent(Bool.self, forKey: .ollamaEnabled) ?? false
		ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "llama3.2"
		ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434"
	}
}

extension SharedReaderKey
	where Self == FileStorageKey<HexSettings>.Default
{
	static var hexSettings: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "hex_settings.json")),
			default: .init()
		]
	}
}
