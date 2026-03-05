import Foundation
import os.log

private let transcriptionLog = OSLog(subsystem: "com.speaklow.app", category: "Transcription")

class TranscriptionService {
    private let bridgeURL: String
    private let transcriptionTimeoutSeconds: TimeInterval = 30

    init(bridgeURL: String = "http://localhost:18089") {
        self.bridgeURL = bridgeURL
    }

    func transcribe(fileURL: URL) async throws -> String {
        os_log(.info, log: transcriptionLog, "transcribe() called with file: %{public}@", fileURL.lastPathComponent)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw TranscriptionError.submissionFailed("Service deallocated")
                }
                return try await self.transcribeAudio(fileURL: fileURL)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.transcriptionTimeoutSeconds * 1_000_000_000))
                throw TranscriptionError.transcriptionTimedOut(self.transcriptionTimeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw TranscriptionError.submissionFailed("No transcription result")
            }
            group.cancelAll()
            os_log(.info, log: transcriptionLog, "transcribe() returning text length=%d", result.count)
            return result
        }
    }

    /// Convert audio to 16kHz 16-bit mono WAV using afconvert (required by FunASR)
    private func convertTo16kMono(fileURL: URL) throws -> URL {
        let convertedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_16k.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", fileURL.path, convertedURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.submissionFailed("afconvert failed with status \(process.terminationStatus)")
        }
        viLog("Audio converted to 16kHz mono: \(convertedURL.path)")
        return convertedURL
    }

    private func transcribeAudio(fileURL: URL) async throws -> String {
        let url = URL(string: "\(bridgeURL)/v1/transcribe-sync")!
        os_log(.info, log: transcriptionLog, "POST %{public}@", url.absoluteString)

        // Convert to 16kHz 16-bit mono WAV for FunASR
        let convertedURL: URL
        do {
            convertedURL = try convertTo16kMono(fileURL: fileURL)
        } catch {
            viLog("Audio conversion failed: \(error.localizedDescription), sending original")
            convertedURL = fileURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = transcriptionTimeoutSeconds

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData: Data
        do {
            audioData = try Data(contentsOf: convertedURL)
        } catch {
            os_log(.error, log: transcriptionLog, "Failed to read audio file: %{public}@", error.localizedDescription)
            throw TranscriptionError.submissionFailed("Cannot read audio file: \(error.localizedDescription)")
        }
        os_log(.info, log: transcriptionLog, "Audio file size: %d bytes", audioData.count)

        let body = makeMultipartBody(
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            boundary: boundary
        )
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            viLog("Transcription: Sending POST to \(url.absoluteString), body=\(body.count) bytes...")
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
            viLog("Transcription: HTTP response received")
        } catch {
            viLog("Transcription: HTTP request FAILED: \(error.localizedDescription)")
            os_log(.error, log: transcriptionLog, "HTTP request failed: %{public}@", error.localizedDescription)
            throw TranscriptionError.submissionFailed("Network error: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            viLog("Transcription: No HTTP response object")
            os_log(.error, log: transcriptionLog, "No HTTP response")
            throw TranscriptionError.submissionFailed("No response from server")
        }

        viLog("Transcription: HTTP \(httpResponse.statusCode), body=\(data.count) bytes")
        os_log(.info, log: transcriptionLog, "HTTP %d, body=%d bytes", httpResponse.statusCode, data.count)

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            os_log(.error, log: transcriptionLog, "Server error: %{public}@", responseBody)
            throw TranscriptionError.submissionFailed("Status \(httpResponse.statusCode): \(responseBody)")
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        os_log(.info, log: transcriptionLog, "Response: %{public}@", responseStr)

        // Clean up converted temp file
        if convertedURL != fileURL {
            try? FileManager.default.removeItem(at: convertedURL)
        }

        return try parseTranscript(from: data)
    }

    private func makeMultipartBody(audioData: Data, fileName: String, boundary: String) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioContentType(for: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/wav"
    }

    private func parseTranscript(from data: Data) throws -> String {
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            os_log(.info, log: transcriptionLog, "Parsed text: %{public}@", text)
            return text
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        os_log(.error, log: transcriptionLog, "Failed to parse response: %{public}@", raw)
        throw TranscriptionError.pollFailed("Invalid response format")
    }

    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(bridgeURL)/health") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                os_log(.error, log: transcriptionLog, "Health check failed")
                return false
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                os_log(.info, log: transcriptionLog, "Health check: %{public}@", status)
                return status == "ok"
            }
            return false
        } catch {
            os_log(.error, log: transcriptionLog, "Health check error: %{public}@", error.localizedDescription)
            return false
        }
    }
}

enum TranscriptionError: LocalizedError {
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        }
    }
}
