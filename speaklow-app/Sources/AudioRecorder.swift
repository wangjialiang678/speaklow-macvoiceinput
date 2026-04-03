import AVFoundation
import CoreAudio
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.speaklow.app", category: "Recording")

struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType) == noErr else {
            return nil
        }
        return transportType
    }

    static func availableInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [AudioDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputStreamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            let bufferListRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(streamSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListRaw.deallocate() }
            let bufferListPointer = bufferListRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(deviceID, &inputStreamAddress, 0, nil, &streamSize, bufferListPointer) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let uidRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(uidSize),
                alignment: MemoryLayout<CFString?>.alignment
            )
            defer { uidRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidRaw) == noErr else { continue }
            guard let uidRef = uidRaw.load(as: CFString?.self) else { continue }
            let uid = uidRef as String
            guard !uid.isEmpty else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let nameRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(nameSize),
                alignment: MemoryLayout<CFString?>.alignment
            )
            defer { nameRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, nameRaw) == noErr else { continue }
            guard let nameRef = nameRaw.load(as: CFString?.self) else { continue }
            let name = nameRef as String
            guard !name.isEmpty else { continue }

            devices.append(AudioDevice(id: deviceID, uid: uid, name: name))
        }
        return devices
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        // Look up through the enumerated devices to avoid CFString pointer issues
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }

    static func defaultInputDeviceUID() -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return nil
        }
        return availableInputDevices().first(where: { $0.id == deviceID })?.uid
    }

    static func builtInMicrophoneUID() -> String? {
        availableInputDevices().first { device in
            transportType(for: device.id) == kAudioDeviceTransportTypeBuiltIn
        }?.uid
    }

    static func deviceName(forUID uid: String) -> String? {
        availableInputDevices().first(where: { $0.uid == uid })?.name
    }

    static func isBluetoothDevice(uid: String) -> Bool {
        guard let deviceID = deviceID(forUID: uid),
              let transportType = transportType(for: deviceID) else {
            let deviceName = deviceName(forUID: uid)?.lowercased() ?? ""
            return deviceName.contains("bluetooth")
        }
        return transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        }
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private let streamingSampleRate: Double = 16000
    private let streamingChannels: AVAudioChannelCount = 1
    private let maxRetainedRecordings = 20
    private static let recordingCacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SpeakLow/recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private let audioFileQueue = DispatchQueue(label: "com.speaklow.app.audiofile")
    private var recordingStartTime: CFAbsoluteTime = 0
    private var firstBufferLogged = false
    private var bufferCount: Int = 0
    private var currentDeviceUID: String?
    private var storedInputFormat: AVAudioFormat?
    /// Voice Processing IO 降噪是否成功启用
    private(set) var voiceProcessingEnabled = false

    @Published var isRecording = false
    /// Thread-safe flag read from the audio tap callback.
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0

    /// Called on the audio thread when the first non-silent buffer arrives.
    var onRecordingReady: (() -> Void)?
    /// Called when no non-silent audio is detected within the timeout period.
    var onSilenceTimeout: (() -> Void)?
    /// Called on the audio thread with 16kHz 16-bit mono PCM data for streaming.
    /// Each callback delivers exactly 3200 bytes (100ms of audio).
    var onStreamingAudioChunk: ((Data) -> Void)?
    private var readyFired = false
    private var silenceTimer: DispatchSourceTimer?
    // Streaming PCM conversion / 16kHz WAV persistence
    private var streamingConverter: AVAudioConverter?
    private var streamingOutputFormat: AVAudioFormat?
    private var streamingBuffer = Data()
    private let streamingChunkSize = 3200 // 100ms at 16kHz 16-bit mono
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    func startRecording(deviceUID: String? = nil) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        firstBufferLogged = false
        bufferCount = 0
        readyFired = false
        let resolvedDeviceUID: String? = {
            guard let uid = deviceUID, !uid.isEmpty else {
                return AudioDevice.defaultInputDeviceUID()
            }
            if uid == "default" {
                return AudioDevice.defaultInputDeviceUID()
            }
            return uid
        }()

        os_log(.info, log: recordingLog, "startRecording() entered")

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioRecorderError.missingInputDevice
        }
        os_log(.info, log: recordingLog, "AVCaptureDevice check: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        // Reuse existing engine if same device, otherwise build new one
        if let _ = audioEngine, currentDeviceUID == resolvedDeviceUID {
            os_log(.info, log: recordingLog, "reusing existing engine: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        } else {
            // Tear down old engine if device changed
            if audioEngine != nil {
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine?.stop()
                audioEngine = nil
            }

            let engine = AVAudioEngine()
            os_log(.info, log: recordingLog, "AVAudioEngine created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            // Set specific input device if requested
            if let uid = resolvedDeviceUID, !uid.isEmpty,
               let deviceID = AudioDevice.deviceID(forUID: uid) {
                os_log(.info, log: recordingLog, "device lookup resolved to %d: %.3fms", deviceID, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let inputUnit = engine.inputNode.audioUnit!
                var id = deviceID
                AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }

            let inputNode = engine.inputNode
            os_log(.info, log: recordingLog, "inputNode accessed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            // TODO: Voice Processing IO 降噪暂不启用
            // 原因：启用后 inputNode 格式变为 48kHz 3ch，AVAudioConverter 转 16kHz mono 时
            // 产出近零数据（-91dB），导致 ASR 收到静音。需要先修复多声道转换问题。
            // 备选方案：RNNoise（纯 C 库）或 GTCRN（via sherpa-onnx）

            let inputFormat = inputNode.outputFormat(forBus: 0)
            os_log(.info, log: recordingLog, "inputFormat retrieved (rate=%.0f, ch=%d): %.3fms", inputFormat.sampleRate, inputFormat.channelCount, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard inputFormat.sampleRate > 0 else {
                throw AudioRecorderError.invalidInputFormat("Invalid sample rate: \(inputFormat.sampleRate)")
            }
            guard inputFormat.channelCount > 0 else {
                throw AudioRecorderError.invalidInputFormat("No input channels available")
            }

            storedInputFormat = inputFormat

            // Set up streaming converter (native format → 16kHz mono int16)
            if let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: streamingSampleRate, channels: streamingChannels, interleaved: true) {
                self.streamingOutputFormat = outFmt
                self.streamingConverter = AVAudioConverter(from: inputFormat, to: outFmt)
                self.streamingBuffer = Data()
                os_log(.info, log: recordingLog, "streaming converter: %.0fHz %dch → 16kHz mono", inputFormat.sampleRate, inputFormat.channelCount)
            }

            // Install tap — checks isRecording and audioFile dynamically
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self, self._recording.withLock({ $0 }) else { return }

                self.bufferCount += 1

                // Check if this buffer has real audio
                var rms: Float = 0
                let frames = Int(buffer.frameLength)
                if frames > 0, let channelData = buffer.floatChannelData {
                    let samples = channelData[0]
                    var sum: Float = 0
                    for i in 0..<frames { sum += samples[i] * samples[i] }
                    rms = sqrtf(sum / Float(frames))
                }

                if self.bufferCount <= 40 {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                    os_log(.info, log: recordingLog, "buffer #%d at %.3fms, frames=%d, rms=%.6f", self.bufferCount, elapsed, buffer.frameLength, rms)
                }

                // Fire ready callback on first non-silent buffer
                if !self.readyFired && rms > 0 {
                    self.readyFired = true
                    self.silenceTimer?.cancel()
                    self.silenceTimer = nil
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                    os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
                    self.onRecordingReady?()
                }

                // Streaming: convert to 16kHz mono PCM, write WAV, and deliver 3200-byte chunks
                if let converter = self.streamingConverter,
                   let outFmt = self.streamingOutputFormat {
                    let ratio = outFmt.sampleRate / inputFormat.sampleRate
                    let outFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                    if let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrameCount) {
                        var convError: NSError?
                        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                            outStatus.pointee = .haveData
                            return buffer
                        }
                        if status == .haveData, let int16Ptr = outBuf.int16ChannelData {
                            let byteCount = Int(outBuf.frameLength) * 2
                            let pcmData = Data(bytes: int16Ptr[0], count: byteCount)

                            // 收集待发送的 chunk，在锁外回调避免持锁时执行耗时操作
                            var chunksToDeliver: [Data] = []
                            self.audioFileQueue.sync {
                                if let file = self.audioFile {
                                    do {
                                        try file.write(from: outBuf)
                                    } catch {
                                        self.audioFile = nil
                                    }
                                }
                                self.streamingBuffer.append(pcmData)
                                while self.streamingBuffer.count >= self.streamingChunkSize {
                                    let chunk = self.streamingBuffer.prefix(self.streamingChunkSize)
                                    chunksToDeliver.append(Data(chunk))
                                    self.streamingBuffer.removeFirst(self.streamingChunkSize)
                                }
                            }

                            // 锁外回调
                            for chunk in chunksToDeliver {
                                self.onStreamingAudioChunk?(chunk)
                            }
                        }
                    }
                }

                self.computeAudioLevel(from: buffer)
            }
            os_log(.info, log: recordingLog, "tap installed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            engine.prepare()
            os_log(.info, log: recordingLog, "engine prepared: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            self.audioEngine = engine
            self.currentDeviceUID = resolvedDeviceUID
        }

        // Start engine if not already running
        if let engine = audioEngine, !engine.isRunning {
            try engine.start()
            os_log(.info, log: recordingLog, "engine started: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        guard let inputFormat = storedInputFormat else {
            throw AudioRecorderError.invalidInputFormat("No stored input format")
        }

        if let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: streamingSampleRate, channels: streamingChannels, interleaved: true) {
            self.streamingOutputFormat = outFmt
            self.streamingConverter = AVAudioConverter(from: inputFormat, to: outFmt)
            audioFileQueue.sync { self.streamingBuffer.removeAll() }
        } else {
            throw AudioRecorderError.invalidInputFormat("Failed to create 16kHz output format")
        }

        // Create recording file in cache directory
        pruneOldRecordings()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileURL = Self.recordingCacheDir.appendingPathComponent("recording-\(timestamp).wav")
        self.tempFileURL = fileURL

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: streamingSampleRate,
            AVNumberOfChannelsKey: streamingChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let newAudioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: wavSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        os_log(.info, log: recordingLog, "audio file created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        audioFileQueue.sync { self.audioFile = newAudioFile }
        _recording.withLock { $0 = true }
        self.isRecording = true

        // Start silence detection timer — if no real audio within 2s, fire callback
        silenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, !self.readyFired else { return }
            os_log(.error, log: recordingLog, "Silence timeout — no audio detected in 2s, engine may be stale")
            // Force engine teardown so next recording rebuilds it
            self.invalidateEngine()
            self.onSilenceTimeout?()
        }
        timer.resume()
        silenceTimer = timer

        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    override init() {
        super.init()

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.invalidateEngine()
            os_log(.info, log: recordingLog, "默认输入设备已变更，引擎已重置")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            os_log(.error, log: recordingLog, "注册默认输入设备监听失败: %d", status)
            return
        }
        defaultInputDeviceListenerBlock = block
    }

    deinit {
        guard let block = defaultInputDeviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    func stopRecording() -> URL? {
        let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", elapsed, bufferCount)

        silenceTimer?.cancel()
        silenceTimer = nil
        _recording.withLock { $0 = false }
        audioFileQueue.sync { audioFile = nil }
        isRecording = false
        smoothedLevel = 0.0
        DispatchQueue.main.async { self.audioLevel = 0.0 }

        // Flush remaining streaming buffer（在锁内读取并清空，锁外回调）
        var remaining = Data()
        audioFileQueue.sync {
            if !self.streamingBuffer.isEmpty {
                remaining = self.streamingBuffer
                self.streamingBuffer.removeAll()
            }
        }
        if !remaining.isEmpty {
            onStreamingAudioChunk?(remaining)
        }

        // Stop engine so mic indicator goes away — keep engine object for fast restart
        audioEngine?.stop()
        os_log(.info, log: recordingLog, "engine stopped (mic indicator off)")

        return tempFileURL
    }

    private func computeAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumOfSquares: Float = 0.0
        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            for i in 0..<frames {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
        } else if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            for i in 0..<frames {
                let sample = Float(samples[i]) / Float(Int16.max)
                sumOfSquares += sample * sample
            }
        } else {
            return
        }

        let rms = sqrtf(sumOfSquares / Float(frames))

        // Log scale: maps RMS to 0-1 matching human loudness perception
        // RMS 0.001 → 0, RMS 0.01 → 0.25, RMS 0.05 → 0.67, RMS 0.10 → 0.85, RMS 0.30 → 1.0
        let rmsDb = 20.0 * log10f(max(rms, 0.001))
        let scaled = min(max((rmsDb + 60.0) / 50.0, 0.0), 1.0)

        // Fast attack, moderate release — responsive to speech dynamics
        if scaled > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.1 + scaled * 0.9
        } else {
            smoothedLevel = smoothedLevel * 0.4 + scaled * 0.6
        }

        DispatchQueue.main.async {
            self.audioLevel = self.smoothedLevel
        }
    }

    /// Tear down the audio engine so the next recording rebuilds it from scratch.
    func invalidateEngine() {
        _recording.withLock { $0 = false }
        audioFileQueue.sync { audioFile = nil }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        storedInputFormat = nil
        currentDeviceUID = nil
        isRecording = false
        smoothedLevel = 0.0
        streamingConverter = nil
        streamingOutputFormat = nil
        voiceProcessingEnabled = false
        audioFileQueue.sync { self.streamingBuffer.removeAll() }
        onStreamingAudioChunk = nil
        DispatchQueue.main.async { self.audioLevel = 0.0 }
        os_log(.info, log: recordingLog, "Engine invalidated — will rebuild on next recording")
    }

    private func pruneOldRecordings() {
        let fm = FileManager.default
        let dir = Self.recordingCacheDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "wav" })
            .sorted(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            })
        else { return }

        if files.count > maxRetainedRecordings {
            for file in files.dropFirst(maxRetainedRecordings) {
                try? fm.removeItem(at: file)
                os_log(.info, log: recordingLog, "Pruned old recording: %{public}@", file.lastPathComponent)
            }
        }
    }
}
