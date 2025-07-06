import AVFoundation
import ComposableArchitecture
import Dependencies
import SwiftUI
import Inject

// MARK: - Models

struct Transcript: Codable, Equatable, Identifiable {
	var id: UUID
	var timestamp: Date
	var text: String
	var audioPath: URL
	var duration: TimeInterval
	
	init(id: UUID = UUID(), timestamp: Date, text: String, audioPath: URL, duration: TimeInterval) {
		self.id = id
		self.timestamp = timestamp
		self.text = text
		self.audioPath = audioPath
		self.duration = duration
	}
}

struct TranscriptionHistory: Codable, Equatable {
	var history: [Transcript] = []
}

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "transcription_history.json")),
			default: .init()
		]
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	var onPlaybackFinished: (() -> Void)?

	func play(url: URL) throws -> AVAudioPlayer {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		player.play()
		self.player = player
		return player
	}

	func stop() {
		player?.stop()
		player = nil
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		self.player = nil
		Task { @MainActor in
			onPlaybackFinished?()
		}
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		@Shared(.hexSettings) var hexSettings: HexSettings
		var playingTranscriptID: UUID?
		var audioPlayer: AVAudioPlayer?
		var audioPlayerController: AudioPlayerController?
		
		// Selection and Summary
		var selectedTranscriptIDs: Set<UUID> = []
		var isSelectionMode: Bool = false
		var isSummarySheetPresented: Bool = false
		var isGeneratingSummary: Bool = false
		var generatedSummary: String?
		var summaryError: String?
		var availableOllamaModels: [OllamaModel] = []
		var ollamaAvailable: Bool = false
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished
		case navigateToSettings
		
		// Selection and Summary
		case toggleSelectionMode
		case toggleTranscriptSelection(UUID)
		case selectAllTranscripts
		case deselectAllTranscripts
		case generateSummary
		case dismissSummarySheet
		case checkOllamaAvailability
		case ollamaAvailabilityChecked(Bool)
		case loadOllamaModels
		case ollamaModelsLoaded([OllamaModel])
		case summaryGenerated(String)
		case summaryGenerationFailed(String)
		case regenerateSummary
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.ollama) var ollama

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					// Stop playback if tapping the same transcript
					state.audioPlayerController?.stop()
					state.audioPlayer = nil
					state.audioPlayerController = nil
					state.playingTranscriptID = nil
					return .none
				}

				// Stop any existing playback
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil

				// Find the transcript and play its audio
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				do {
					let controller = AudioPlayerController()
					let player = try controller.play(url: transcript.audioPath)

					state.audioPlayer = player
					state.audioPlayerController = controller
					state.playingTranscriptID = id

					return .run { send in
						// Using non-throwing continuation since we don't need to throw errors
						await withCheckedContinuation { continuation in
							controller.onPlaybackFinished = {
								continuation.resume()

								// Use Task to switch to MainActor for sending the action
								Task { @MainActor in
									send(.playbackFinished)
								}
							}
						}
					}
				} catch {
					print("Error playing audio: \(error)")
					return .none
				}

			case .stopPlayback, .playbackFinished:
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil
				return .none

			case let .copyToClipboard(text):
				return .run { _ in
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.audioPlayerController?.stop()
					state.audioPlayer = nil
					state.audioPlayerController = nil
					state.playingTranscriptID = nil
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				return .run { _ in
					try? FileManager.default.removeItem(at: transcript.audioPath)
				}

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history

				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				return .run { _ in
					for transcript in transcripts {
						try? FileManager.default.removeItem(at: transcript.audioPath)
					}
				}
				
			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none
			
			// Selection and Summary Actions
			case .toggleSelectionMode:
				state.isSelectionMode.toggle()
				if !state.isSelectionMode {
					state.selectedTranscriptIDs.removeAll()
				}
				return .none
				
			case let .toggleTranscriptSelection(id):
				if state.selectedTranscriptIDs.contains(id) {
					state.selectedTranscriptIDs.remove(id)
				} else {
					state.selectedTranscriptIDs.insert(id)
				}
				return .none
				
			case .selectAllTranscripts:
				state.selectedTranscriptIDs = Set(state.transcriptionHistory.history.map(\.id))
				return .none
				
			case .deselectAllTranscripts:
				state.selectedTranscriptIDs.removeAll()
				return .none
				
			case .generateSummary:
				guard !state.selectedTranscriptIDs.isEmpty,
					  state.hexSettings.ollamaEnabled else {
					return .none
				}
				
				print("🤖 Starting summary generation...")
				print("🤖 Selected transcripts: \(state.selectedTranscriptIDs.count)")
				print("🤖 Using model: \(state.hexSettings.ollamaModel)")
				print("🤖 Ollama URL: \(state.hexSettings.ollamaBaseURL)")
				
				state.isSummarySheetPresented = true
				state.isGeneratingSummary = true
				state.generatedSummary = nil
				state.summaryError = nil
				
				let selectedTranscripts = state.transcriptionHistory.history.filter {
					state.selectedTranscriptIDs.contains($0.id)
				}
				
				let combinedText = selectedTranscripts
					.sorted(by: { $0.timestamp < $1.timestamp })
					.map { "[\($0.timestamp.formatted(date: .abbreviated, time: .shortened))] \($0.text)" }
					.joined(separator: "\n\n")
				
				print("🤖 Combined text length: \(combinedText.count) characters")
				
				let prompt = """
				Please provide a concise summary of the following transcribed conversations. Focus on the key topics, decisions, and action items mentioned:

				\(combinedText)

				Summary:
				"""
				
				return .run { [model = state.hexSettings.ollamaModel, baseURL = state.hexSettings.ollamaBaseURL] send in
					do {
						print("🤖 Sending request to Ollama...")
						let summary = try await ollama.generateSummary(prompt, model, baseURL)
						print("🤖 Summary generated successfully: \(summary.count) characters")
						await send(.summaryGenerated(summary))
					} catch {
						print("🤖 Summary generation failed: \(error.localizedDescription)")
						await send(.summaryGenerationFailed(error.localizedDescription))
					}
				}
				
			case .dismissSummarySheet:
				state.isSummarySheetPresented = false
				state.isGeneratingSummary = false
				state.generatedSummary = nil
				state.summaryError = nil
				return .none
				
			case .checkOllamaAvailability:
				return .run { [baseURL = state.hexSettings.ollamaBaseURL] send in
					let available = await ollama.isAvailable(baseURL)
					await send(.ollamaAvailabilityChecked(available))
				}
				
			case let .ollamaAvailabilityChecked(available):
				state.ollamaAvailable = available
				if available {
					return .send(.loadOllamaModels)
				}
				return .none
				
			case .loadOllamaModels:
				return .run { [baseURL = state.hexSettings.ollamaBaseURL] send in
					do {
						let models = try await ollama.getAvailableModels(baseURL)
						await send(.ollamaModelsLoaded(models))
					} catch {
						// Silently fail if can't load models
						await send(.ollamaModelsLoaded([]))
					}
				}
				
			case let .ollamaModelsLoaded(models):
				state.availableOllamaModels = models
				return .none
				
			case let .summaryGenerated(summary):
				state.isGeneratingSummary = false
				state.generatedSummary = summary
				return .none
				
			case let .summaryGenerationFailed(error):
				state.isGeneratingSummary = false
				state.summaryError = error
				return .none
				
			case .regenerateSummary:
				guard !state.selectedTranscriptIDs.isEmpty,
					  state.hexSettings.ollamaEnabled else {
					return .none
				}
				
				print("🤖 Regenerating summary...")
				
				state.isGeneratingSummary = true
				state.generatedSummary = nil
				state.summaryError = nil
				
				let selectedTranscripts = state.transcriptionHistory.history.filter {
					state.selectedTranscriptIDs.contains($0.id)
				}
				
				let combinedText = selectedTranscripts
					.sorted(by: { $0.timestamp < $1.timestamp })
					.map { "[\($0.timestamp.formatted(date: .abbreviated, time: .shortened))] \($0.text)" }
					.joined(separator: "\n\n")
				
				let prompt = """
				Please provide a concise summary of the following transcribed conversations. Focus on the key topics, decisions, and action items mentioned:

				\(combinedText)

				Summary:
				"""
				
				return .run { [model = state.hexSettings.ollamaModel, baseURL = state.hexSettings.ollamaBaseURL] send in
					do {
						print("🤖 Sending regeneration request to Ollama...")
						let summary = try await ollama.generateSummary(prompt, model, baseURL)
						print("🤖 Summary regenerated successfully: \(summary.count) characters")
						await send(.summaryGenerated(summary))
					} catch {
						print("🤖 Summary regeneration failed: \(error.localizedDescription)")
						await send(.summaryGenerationFailed(error.localizedDescription))
					}
				}
			}
		}
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	let isSelected: Bool
	let isSelectionMode: Bool
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void
	let onToggleSelection: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(transcript.text)
				.font(.body)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.trailing, 40) // Space for buttons
				.padding(12)

			Divider()

			HStack {
				HStack(spacing: 6) {
					Image(systemName: "clock")
					Text(transcript.timestamp.formatted(date: .numeric, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					if isSelectionMode {
						Button(action: onToggleSelection) {
							Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
						}
						.buttonStyle(.plain)
						.foregroundStyle(isSelected ? .blue : .secondary)
						.help(isSelected ? "Deselect" : "Select")
					} else {
						Button {
							onCopy()
							showCopyAnimation()
						} label: {
							HStack(spacing: 4) {
								Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
								if showCopied {
									Text("Copied").font(.caption)
								}
							}
						}
						.buttonStyle(.plain)
						.foregroundStyle(showCopied ? .green : .secondary)
						.help("Copy to clipboard")

						Button(action: onPlay) {
							Image(systemName: isPlaying ? "stop.fill" : "play.fill")
						}
						.buttonStyle(.plain)
						.foregroundStyle(isPlaying ? .blue : .secondary)
						.help(isPlaying ? "Stop playback" : "Play audio")

						Button(action: onDelete) {
							Image(systemName: "trash.fill")
						}
						.buttonStyle(.plain)
						.foregroundStyle(.secondary)
						.help("Delete transcript")
					}
				}
				.font(.subheadline)
			}
			.frame(height: 20)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color(.windowBackgroundColor).opacity(isSelected ? 0.8 : 0.5))
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.strokeBorder(isSelected ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
				)
		)
		.onDisappear {
			// Clean up any running task when view disappears
			copyTask?.cancel()
		}
	}

	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?

	private func showCopyAnimation() {
		copyTask?.cancel()

		copyTask = Task {
			withAnimation {
				showCopied = true
			}

			try await Task.sleep(for: .seconds(1.5))

			withAnimation {
				showCopied = false
			}
		}
	}
}

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/Users/langton/Downloads/test.m4a"), duration: 1.0),
		isPlaying: false,
		isSelected: false,
		isSelectionMode: false,
		onPlay: {},
		onCopy: {},
		onDelete: {},
		onToggleSelection: {}
	)
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings

	var body: some View {
      Group {
        if !hexSettings.saveTranscriptionHistory {
          ContentUnavailableView {
            Label("History Disabled", systemImage: "clock.arrow.circlepath")
          } description: {
            Text("Transcription history is currently disabled.")
          } actions: {
            Button("Enable in Settings") {
              store.send(.navigateToSettings)
            }
          }
        } else if store.transcriptionHistory.history.isEmpty {
          ContentUnavailableView {
            Label("No Transcriptions", systemImage: "text.bubble")
          } description: {
            Text("Your transcription history will appear here.")
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(store.transcriptionHistory.history) { transcript in
                TranscriptView(
                  transcript: transcript,
                  isPlaying: store.playingTranscriptID == transcript.id,
                  isSelected: store.selectedTranscriptIDs.contains(transcript.id),
                  isSelectionMode: store.isSelectionMode,
                  onPlay: { store.send(.playTranscript(transcript.id)) },
                  onCopy: { store.send(.copyToClipboard(transcript.text)) },
                  onDelete: { store.send(.deleteTranscript(transcript.id)) },
                  onToggleSelection: { store.send(.toggleTranscriptSelection(transcript.id)) }
                )
              }
            }
            .padding()
          }
          .toolbar {
            ToolbarItemGroup(placement: .automatic) {
              if store.isSelectionMode {
                Button("Select All") {
                  store.send(.selectAllTranscripts)
                }
                .disabled(store.selectedTranscriptIDs.count == store.transcriptionHistory.history.count)
                
                Button("Deselect All") {
                  store.send(.deselectAllTranscripts)
                }
                .disabled(store.selectedTranscriptIDs.isEmpty)
                
                if store.hexSettings.ollamaEnabled && store.ollamaAvailable {
                  Button("Generate Summary") {
                    store.send(.generateSummary)
                  }
                  .disabled(store.selectedTranscriptIDs.isEmpty)
                }
                
                Button("Done") {
                  store.send(.toggleSelectionMode)
                }
              } else {
                if store.hexSettings.ollamaEnabled && store.ollamaAvailable {
                  Button("Select") {
                    store.send(.toggleSelectionMode)
                  }
                  .disabled(store.transcriptionHistory.history.isEmpty)
                }
                
                Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
                  Label("Delete All", systemImage: "trash")
                }
              }
            }
          }
          .alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
              store.send(.confirmDeleteAll)
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
          }
        }
      }
      .onAppear {
        if store.hexSettings.ollamaEnabled {
          store.send(.checkOllamaAvailability)
        }
      }
      .sheet(isPresented: Binding(
        get: { store.isSummarySheetPresented },
        set: { _ in store.send(.dismissSummarySheet) }
      )) {
        SummaryView(
          isGenerating: store.isGeneratingSummary,
          summary: store.generatedSummary,
          error: store.summaryError,
          selectedCount: store.selectedTranscriptIDs.count,
          onDismiss: { store.send(.dismissSummarySheet) },
          onRegenerate: { store.send(.regenerateSummary) }
        )
      }
      .enableInjection()
	}
}

struct SummaryView: View {
  @ObserveInjection var inject
  let isGenerating: Bool
  let summary: String?
  let error: String?
  let selectedCount: Int
  let onDismiss: () -> Void
  let onRegenerate: () -> Void
  
  @State private var showCopied = false
  @State private var copyTask: Task<Void, Error>?

  var body: some View {
    VStack(spacing: 0) {
      // Custom navigation bar
      HStack {
        Text("Summary")
          .font(.title2)
          .fontWeight(.semibold)
        
        Spacer()
        
        Button("Done") {
          onDismiss()
        }
        .buttonStyle(.borderedProminent)
      }
      .padding()
      .background(Color(.windowBackgroundColor))
      
      Divider()
      
      // Main content
      VStack(spacing: 24) {
        // Header
        HStack {
          Image(systemName: "doc.text")
            .foregroundColor(.blue)
            .font(.title2)
          Text("Summary of \(selectedCount) transcription\(selectedCount == 1 ? "" : "s")")
            .font(.headline)
          Spacer()
        }
        .padding(.horizontal)
        
        // Content area
        if isGenerating {
          Spacer()
          VStack(spacing: 16) {
            ProgressView()
              .scaleEffect(1.2)
            Text("Generating summary with Ollama...")
              .foregroundColor(.secondary)
              .font(.body)
          }
          .frame(maxWidth: .infinity)
          Spacer()
          
        } else if let summary = summary {
          // Summary content
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              Text(summary)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                  RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
                    .stroke(Color(.separatorColor), lineWidth: 1)
                )
            }
            .padding(.horizontal)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          
          // Action buttons
          HStack(spacing: 16) {
            Button(showCopied ? "Copied!" : "Copy to Clipboard") {
              copyToClipboard(summary)
            }
            .buttonStyle(.borderedProminent)
            .opacity(showCopied ? 0.6 : 1.0)
            .keyboardShortcut("c", modifiers: .command)
            .disabled(showCopied)
            
            Button("Regenerate") {
              onRegenerate()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
          }
          .padding(.horizontal, 24)
          .padding(.top, 20)
          .padding(.bottom, 24)
          
        } else if let error = error {
          Spacer()
          VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundColor(.orange)
              .font(.system(size: 48))
            
            Text("Summary Generation Failed")
              .font(.title2)
              .fontWeight(.semibold)
            
            Text(error)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
              .font(.body)
          }
          .frame(maxWidth: .infinity)
          .padding(.horizontal)
          
          Button("Try Again") {
            onRegenerate()
          }
          .buttonStyle(.borderedProminent)
          .padding(.top)
          
          Spacer()
        }
      }
      .padding(.top)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 500, minHeight: 400)
    .onDisappear {
      copyTask?.cancel()
    }
    .enableInjection()
  }
  
  private func copyToClipboard(_ text: String) {
    // Cancel any existing copy task
    copyTask?.cancel()
    
    // Copy to clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    
    // Show "Copied!" feedback
    withAnimation(.easeInOut(duration: 0.2)) {
      showCopied = true
    }
    
    // Reset after 2 seconds
    copyTask = Task {
      try await Task.sleep(for: .seconds(2))
      if !Task.isCancelled {
        withAnimation(.easeInOut(duration: 0.2)) {
          showCopied = false
        }
      }
    }
  }
}
