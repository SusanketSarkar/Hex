//
//  OllamaClient.swift
//  Hex
//
//  Created by Kit Langton on 1/30/25.
//

import Dependencies
import DependenciesMacros
import Foundation

struct OllamaModel: Codable, Equatable, Identifiable {
  let name: String
  let modifiedAt: String
  let size: Int64
  
  var id: String { name }
  
  enum CodingKeys: String, CodingKey {
    case name
    case modifiedAt = "modified_at"
    case size
  }
}

struct OllamaModelsResponse: Codable {
  let models: [OllamaModel]
}

struct OllamaGenerateRequest: Codable {
  let model: String
  let prompt: String
  let stream: Bool = false
}

struct OllamaGenerateResponse: Codable {
  let model: String
  let response: String
  let done: Bool
}

@DependencyClient
struct OllamaClient {
  /// Generates a summary using the specified Ollama model
  var generateSummary: @Sendable (String, String, String) async throws -> String = { _, _, _ in "" }
  
  /// Gets available models from Ollama
  var getAvailableModels: @Sendable (String) async throws -> [OllamaModel] = { _ in [] }
  
  /// Checks if Ollama is running and accessible
  var isAvailable: @Sendable (String) async -> Bool = { _ in false }
}

extension OllamaClient: DependencyKey {
  static var liveValue: Self {
    let live = OllamaClientLive()
    return Self(
      generateSummary: { try await live.generateSummary(prompt: $0, model: $1, baseURL: $2) },
      getAvailableModels: { try await live.getAvailableModels(baseURL: $0) },
      isAvailable: { await live.isAvailable(baseURL: $0) }
    )
  }
}

extension DependencyValues {
  var ollama: OllamaClient {
    get { self[OllamaClient.self] }
    set { self[OllamaClient.self] = newValue }
  }
}

actor OllamaClientLive {
  private let session: URLSession
  
  init() {
    self.session = URLSession.shared
  }
  
  func isAvailable(baseURL: String) async -> Bool {
    do {
      let url = URL(string: "\(baseURL)/api/tags")!
      let (_, response) = try await session.data(from: url)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }
  
  func getAvailableModels(baseURL: String) async throws -> [OllamaModel] {
    let url = URL(string: "\(baseURL)/api/tags")!
    let (data, response) = try await session.data(from: url)
    
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
      throw NSError(domain: "OllamaClient", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Ollama server not available"
      ])
    }
    
    let decoder = JSONDecoder()
    let modelsResponse = try decoder.decode(OllamaModelsResponse.self, from: data)
    return modelsResponse.models
  }
  
  func generateSummary(prompt: String, model: String, baseURL: String) async throws -> String {
    let url = URL(string: "\(baseURL)/api/generate")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60 // 60 second timeout
    
    let generateRequest = OllamaGenerateRequest(
      model: model,
      prompt: prompt
    )
    
    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(generateRequest)
    
    do {
      let (data, response) = try await session.data(for: request)
      
      guard let httpResponse = response as? HTTPURLResponse else {
        throw NSError(domain: "OllamaClient", code: 2, userInfo: [
          NSLocalizedDescriptionKey: "Invalid response from Ollama server"
        ])
      }
      
      guard httpResponse.statusCode == 200 else {
        let errorMessage: String
        switch httpResponse.statusCode {
        case 404:
          errorMessage = "Model '\(model)' not found. Make sure the model is installed in Ollama."
        case 500:
          errorMessage = "Ollama server error. Check if the model is loaded and working properly."
        case 503:
          errorMessage = "Ollama server unavailable. Make sure Ollama is running."
        default:
          errorMessage = "Ollama server error (HTTP \(httpResponse.statusCode))"
        }
        
        throw NSError(domain: "OllamaClient", code: httpResponse.statusCode, userInfo: [
          NSLocalizedDescriptionKey: errorMessage
        ])
      }
      
      let decoder = JSONDecoder()
      let generateResponse = try decoder.decode(OllamaGenerateResponse.self, from: data)
      return generateResponse.response
      
    } catch let error as NSError where error.domain == "OllamaClient" {
      // Re-throw our custom errors
      throw error
    } catch {
      // Handle network and other errors
      let errorMessage: String
      if error.localizedDescription.contains("timed out") {
        errorMessage = "Request timed out. The model might be taking too long to respond."
      } else if error.localizedDescription.contains("connection") {
        errorMessage = "Cannot connect to Ollama. Make sure Ollama is running on \(baseURL)"
      } else {
        errorMessage = "Network error: \(error.localizedDescription)"
      }
      
      throw NSError(domain: "OllamaClient", code: 1, userInfo: [
        NSLocalizedDescriptionKey: errorMessage
      ])
    }
  }
} 