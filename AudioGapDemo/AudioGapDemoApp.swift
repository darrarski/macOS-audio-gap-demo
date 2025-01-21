import AVFoundation
import OSLog
import SwiftUI

@main
struct AudioGapDemoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .windowResizability(.contentSize)
  }
}

struct ContentView: View {
  @State var recorder: Recorder?

  var body: some View {
    VStack {
      Button {
        recorder = Recorder()
        recorder?.startCaptureSession()
        recorder?.startRecording()
      } label: {
        Text("Start").frame(maxWidth: .infinity)
      }
      Button {
        recorder?.stopCaptureSession()
        recorder?.finishRecording()
      } label: {
        Text("Finish").frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .padding()
    .frame(width: 200)
  }
}

final class Recorder: NSObject {
  // MARK: - Configuration

  /// Localized name of the capture device. Change to use a different device.
  let deviceName = "MacBook Pro Microphone"

  /// Range of time (in seconds) whithin samples should not be recorded (for gap simulation purposes).
  let sampleSkipTimeRange: Range<Double> = 3..<6

  /// If `true` will append empty samples to fill detected gaps.
  let fillGaps: Bool = true

  // MARK: - Capture session

  private struct CaptureContext {
    let device: AVCaptureDevice
    let session: AVCaptureSession
    let deviceInput: AVCaptureDeviceInput
    let audioOutput: AVCaptureAudioDataOutput
  }

  private let captureQueue = DispatchQueue(label: "Recorder.captureQueue", qos: .utility)
  private let captureLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Capture")
  private var captureContext: CaptureContext?

  func startCaptureSession() {
    stopCaptureSession()
    captureQueue.sync {
      let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
      )
      let devices = discovery.devices
      for device in devices {
        captureLog.info(#"Found device: "\#(device.localizedName)""#)
      }
      let device = devices.first { $0.localizedName == deviceName }
      guard let device else {
        captureLog.error(#"Device "\#(self.deviceName)" not found"#)
        return
      }

      let session = AVCaptureSession()
      session.beginConfiguration()
      session.sessionPreset = .high

      let deviceInput: AVCaptureDeviceInput
      do {
        deviceInput = try AVCaptureDeviceInput(device: device)
      } catch {
        captureLog.error("Could not create video input, error: \(error)")
        return
      }
      guard session.canAddInput(deviceInput) else {
        captureLog.error("Could not add video input")
        return
      }
      session.addInput(deviceInput)

      let audioOutput = AVCaptureAudioDataOutput()
      audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
      guard session.canAddOutput(audioOutput) else {
        captureLog.error("Could not add audio output")
        return
      }
      session.addOutput(audioOutput)

      session.commitConfiguration()
      session.startRunning()

      self.captureContext = CaptureContext(
        device: device,
        session: session,
        deviceInput: deviceInput,
        audioOutput: audioOutput
      )

      captureLog.info("Capture session started")
    }
  }

  func stopCaptureSession() {
    captureQueue.sync {
      guard captureContext != nil else { return }
      self.captureContext?.session.stopRunning()
      self.captureContext = nil
      captureLog.info("Capture session stopped")
    }
  }

  // MARK: - Recording

  private struct RecordingContext {
    let writer: AVAssetWriter
    let writerInput: AVAssetWriterInput
    var startTime: CMTime
    var finishTime: CMTime?
    var firstSampleTime: CMTime?
    var lastSampleTime: CMTime?
    var lastSampleDuration: CMTime?
    var isRecording: Bool { finishTime == nil }
  }

  private let recordingQueue = DispatchQueue(label: "Recorder.recordingQueue", qos: .utility)
  private let recordingLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Recording")
  private var recordingContext: RecordingContext?
  private var isRecording: Bool { recordingContext == nil || recordingContext?.isRecording == true }
  private var isSkippingSamples = false

  func startRecording() {
    recordingQueue.sync {
      guard isRecording else {
        recordingLog.error("Can't start recording while another is ongoing")
        return
      }
      guard let captureContext else {
        recordingLog.error("Can't start recording while no capture is ongoing")
        return
      }

      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "yyyy.MM.dd-HH.mm.ss"
      let timestamp = dateFormatter.string(from: Date())
      let fileUrl = URL.downloadsDirectory
        .appending(path: "AudioGapDemo-\(timestamp)", directoryHint: .notDirectory)
        .appendingPathExtension("mov")

      let fileType = AVFileType.mov
      let writer: AVAssetWriter
      do {
        writer = try AVAssetWriter(outputURL: fileUrl, fileType: fileType)
      } catch {
        recordingLog.error("Could not create AVAssetWriter")
        return
      }

      guard let outputSettings = captureContext.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: fileType)
      else {
        recordingLog.error("Could not get recommended audio settings for asset writer")
        return
      }
      let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
      guard writer.canAdd(writerInput) else {
        recordingLog.error("Could not add writer input")
        return
      }
      writer.add(writerInput)

      guard writer.startWriting() else {
        recordingLog.error("Could not start writing")
        return
      }

      let startTime = CMClock.hostTimeClock.time
      writer.startSession(atSourceTime: startTime)

      self.recordingContext = RecordingContext(
        writer: writer,
        writerInput: writerInput,
        startTime: startTime
      )
      self.isSkippingSamples = false

      recordingLog.info("Recording started")
    }
  }

  func finishRecording() {
    recordingQueue.sync {
      guard var recordingContext, recordingContext.isRecording else {
        recordingLog.error("Can't finish recording while it's not ongoing")
        return
      }

      let finishTime = CMClock.hostTimeClock.time
      recordingContext.finishTime = CMClock.hostTimeClock.time
      self.recordingContext = recordingContext
      recordingLog.info("Finishing recording at: \((finishTime - recordingContext.startTime).seconds)")

      recordingContext.writerInput.markAsFinished()
      recordingContext.writer.endSession(atSourceTime: finishTime)
      let semaphore = DispatchSemaphore(value: 0)
      recordingContext.writer.finishWriting { semaphore.signal() }
      semaphore.wait()
      recordingLog.info("Recording finsihed")

      recordingLog.info("Writer status: \(recordingContext.writer.status.debugDescription)")
      if recordingContext.writer.status != .completed {
        logWriterError()
      }
    }
  }

  private func record(_ sampleBuffer: CMSampleBuffer) {
    guard sampleBuffer.isValid else {
      recordingLog.debug("Skip invalid sample buffer")
      return
    }
    recordingQueue.sync {
      guard let recordingContext, recordingContext.isRecording else {
        recordingLog.debug("Skip sample because recoding is't ongoing")
        return
      }

      let sampleTime = sampleBuffer.presentationTimeStamp
      guard sampleTime >= recordingContext.startTime else {
        recordingLog.debug("Skip sample because it's before recording start time")
        return
      }

      let relativeSampleTime = sampleTime - recordingContext.startTime
      let skipSample = sampleSkipTimeRange.contains(relativeSampleTime.seconds)
      if isSkippingSamples != skipSample {
        isSkippingSamples = skipSample
        if skipSample {
          recordingLog.info("Start skipping samples at: \(relativeSampleTime.seconds)")
        } else {
          recordingLog.info("Stop skipping samples at: \(relativeSampleTime.seconds)")
        }
      }
      guard !skipSample else { return }

      if let lastSampleTime = recordingContext.lastSampleTime,
         let lastSampleDuration = recordingContext.lastSampleDuration
      {
        let expectedSampleTime = lastSampleTime + lastSampleDuration
        let timeGap = sampleTime - expectedSampleTime
        if timeGap > .zero {
          recordingLog.info("""
            Detected gap with duration: \(timeGap.seconds)
            Current sample time: \((sampleTime - recordingContext.startTime).seconds)
            Expected sample time: \((expectedSampleTime - recordingContext.startTime).seconds)
            """)

          if fillGaps {
            let sampleRate = Float64(expectedSampleTime.timescale)
            if let emptySampleBuffer = CMSampleBuffer.silentAudio(
              startFrame: expectedSampleTime.value,
              framesCount: Int(sampleRate * timeGap.seconds),
              sampleRate: sampleRate,
              channelsCount: 2
            ) {
              recordingLog.info("""
                Empty audio start: \((emptySampleBuffer.presentationTimeStamp - recordingContext.startTime).seconds)
                Empty audio end: \((emptySampleBuffer.presentationTimeStamp + emptySampleBuffer.duration - recordingContext.startTime).seconds)
                Empty audio duration: \(emptySampleBuffer.duration.seconds)
                """)
              append(emptySampleBuffer)
            } else {
              recordingLog.error("Could not create empty sample buffer")
            }
          }
        }
      }

      append(sampleBuffer)
    }
  }

  private func append(_ sampleBuffer: CMSampleBuffer) {
    guard var recordingContext else { return }
    guard recordingContext.writerInput.isReadyForMoreMediaData else {
      recordingLog.debug("Skip appending sample buffer, writer input not ready for more media data")
      return
    }
    guard recordingContext.writerInput.append(sampleBuffer) else {
      recordingLog.error("Could not append sample buffer")
      logWriterError()
      return
    }
    if recordingContext.firstSampleTime == nil {
      recordingContext.firstSampleTime = sampleBuffer.presentationTimeStamp
      recordingLog.info("First appended sample time: \((sampleBuffer.presentationTimeStamp - recordingContext.startTime).seconds)")
    }
    recordingContext.lastSampleTime = sampleBuffer.presentationTimeStamp
    recordingContext.lastSampleDuration = sampleBuffer.duration
    self.recordingContext = recordingContext
  }

  private func logWriterError() {
    guard let writerError = recordingContext?.writer.error else { return }
    recordingLog.error("Writer error: \(writerError)")
    for error in (writerError as NSError).underlyingErrors {
      recordingLog.error("Underlying error: \(error)")
      if let description = OSStatus((error as NSError).code).cmSampleBufferErrorDescription {
        recordingLog.error("CMSampleBufferError: \(description)")
      }
    }
  }
}

extension Recorder: AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    record(sampleBuffer)
  }
}

extension AVAssetWriter.Status {
  var debugDescription: String {
    switch self {
    case .unknown: "unknown"
    case .writing: "writing"
    case .completed: "completed"
    case .failed: "failed"
    case .cancelled: "cancelled"
    @unknown default: "unknown default"
    }
  }
}

extension OSStatus {
  var cmSampleBufferErrorDescription: String? {
    switch self {
    case kCMSampleBufferError_AllocationFailed: "kCMSampleBufferError_AllocationFailed"
    case kCMSampleBufferError_RequiredParameterMissing: "kCMSampleBufferError_RequiredParameterMissing"
    case kCMSampleBufferError_AlreadyHasDataBuffer: "kCMSampleBufferError_AlreadyHasDataBuffer"
    case kCMSampleBufferError_BufferNotReady: "kCMSampleBufferError_BufferNotReady"
    case kCMSampleBufferError_SampleIndexOutOfRange: "kCMSampleBufferError_SampleIndexOutOfRange"
    case kCMSampleBufferError_BufferHasNoSampleSizes: "kCMSampleBufferError_BufferHasNoSampleSizes"
    case kCMSampleBufferError_BufferHasNoSampleTimingInfo: "kCMSampleBufferError_BufferHasNoSampleTimingInfo"
    case kCMSampleBufferError_ArrayTooSmall: "kCMSampleBufferError_ArrayTooSmall"
    case kCMSampleBufferError_InvalidEntryCount: "kCMSampleBufferError_InvalidEntryCount"
    case kCMSampleBufferError_CannotSubdivide: "kCMSampleBufferError_CannotSubdivide"
    case kCMSampleBufferError_SampleTimingInfoInvalid: "kCMSampleBufferError_SampleTimingInfoInvalid"
    case kCMSampleBufferError_InvalidMediaTypeForOperation: "kCMSampleBufferError_InvalidMediaTypeForOperation"
    case kCMSampleBufferError_InvalidSampleData: "kCMSampleBufferError_InvalidSampleData"
    case kCMSampleBufferError_InvalidMediaFormat: "kCMSampleBufferError_InvalidMediaFormat"
    case kCMSampleBufferError_Invalidated: "kCMSampleBufferError_Invalidated"
    case kCMSampleBufferError_DataFailed: "kCMSampleBufferError_DataFailed"
    case kCMSampleBufferError_DataCanceled: "kCMSampleBufferError_DataCanceled"
    default: nil
    }
  }
}

extension CMSampleBuffer {
  static func silentAudio(
    startFrame: Int64,
    framesCount: Int,
    sampleRate: Float64,
    channelsCount: UInt32
  ) -> CMSampleBuffer? {
    let bytesPerFrame = UInt32(2 * channelsCount)
    let blockSize = framesCount * Int(bytesPerFrame)

    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: blockSize,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: blockSize,
      flags: 0,
      blockBufferOut: &block
    )
    assert(status == kCMBlockBufferNoErr)
    guard let eBlock = block else { return nil }

    status = CMBlockBufferFillDataBytes(
      with: 0,
      blockBuffer: eBlock,
      offsetIntoDestination: 0,
      dataLength: blockSize
    )
    assert(status == kCMBlockBufferNoErr)

    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: channelsCount,
      mBitsPerChannel: 16,
      mReserved: 0
    )

    var formatDesc: CMAudioFormatDescription?
    status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDesc
    )
    assert(status == noErr)

    var sampleBuffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: eBlock,
      formatDescription: formatDesc!,
      sampleCount: framesCount,
      presentationTimeStamp: CMTimeMake(value: startFrame, timescale: Int32(sampleRate)),
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    )
    assert(status == noErr)

    return sampleBuffer
  }
}
