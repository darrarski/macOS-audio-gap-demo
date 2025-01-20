import AVFoundation
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
  let sampleSkipTimeRange: ClosedRange<Double> = 3...6
  
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
  private var captureContext: CaptureContext?

  func startCaptureSession() {
    stopCaptureSession()
    captureQueue.sync {
      let discrovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
      )
      let devices = discrovery.devices
      for device in devices {
        print("^^^ found device: \"\(device.localizedName)\"")
      }
      let device = devices.first { $0.localizedName == deviceName }
      guard let device else {
        print("^^^ \"\(deviceName)\" device not found")
        return
      }

      let session = AVCaptureSession()
      session.beginConfiguration()
      session.sessionPreset = .high

      let deviceInput: AVCaptureDeviceInput
      do {
        deviceInput = try AVCaptureDeviceInput(device: device)
      } catch {
        print("^^^ Could not create video input, error: \(error)")
        return
      }
      guard session.canAddInput(deviceInput) else {
        print("^^^ Could not add video input")
        return
      }
      session.addInput(deviceInput)

      let audioOutput = AVCaptureAudioDataOutput()
      audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
      guard session.canAddOutput(audioOutput) else {
        print("Could not add audio output")
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

      print("^^^ capture session started")
    }
  }

  func stopCaptureSession() {
    captureQueue.sync {
      guard captureContext != nil else { return }
      self.captureContext?.session.stopRunning()
      self.captureContext = nil
      print("^^^ capture session stopped")
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
  private var recordingContext: RecordingContext?
  private var isRecording: Bool { recordingContext == nil || recordingContext?.isRecording == true }
  private var isSkippingSamples = false

  func startRecording() {
    recordingQueue.sync {
      guard isRecording else {
        print("^^^ cannot start recording while another is ongoing")
        return
      }
      guard let captureContext else {
        print("^^^ cannot start recording while no capture is ongoing")
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
        print("^^^ could not create AVAssetWriter")
        return
      }

      guard let outputSettings = captureContext.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: fileType)
      else {
        print("^^^ could not get recommended audio settings for asset writer")
        return
      }
      let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
      guard writer.canAdd(writerInput) else {
        print("^^^ could not add writer input")
        return
      }
      writer.add(writerInput)

      guard writer.startWriting() else {
        print("^^^ could not start writing")
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

      print("^^^ recording started")
    }
  }

  func finishRecording() {
    recordingQueue.sync {
      guard var recordingContext, recordingContext.isRecording else {
        print("^^^ cannot finish recording while it's not ongoing")
        return
      }
      defer { self.recordingContext = recordingContext }

      let finishTime = CMClock.hostTimeClock.time
      recordingContext.finishTime = CMClock.hostTimeClock.time
      print("^^^ recording finished at: \((finishTime - recordingContext.startTime).seconds)")

      recordingContext.writerInput.markAsFinished()
      recordingContext.writer.endSession(atSourceTime: finishTime)
      let semaphore = DispatchSemaphore(value: 0)
      recordingContext.writer.finishWriting { semaphore.signal() }
      semaphore.wait()

      print("^^^ writer status: \(recordingContext.writer.status.debugDescription)")
      if let writerError = recordingContext.writer.error {
        print("^^^ writer error: \(writerError)")
        for error in (writerError as NSError).underlyingErrors {
          print("^^^ underlying error: \(error)")
          if let description = OSStatus((error as NSError).code).cmSampleBufferErrorDescription {
            print("^^^ CMSampleBufferError: \(description)")
          }
        }
      }
    }
  }

  private func record(_ sampleBuffer: CMSampleBuffer) {
    guard sampleBuffer.isValid else {
      print("^^^ skip invalid sample buffer")
      return
    }
    recordingQueue.sync {
      guard var recordingContext, recordingContext.isRecording else {
        // print("^^^ skip sample because we are not recoding now")
        return
      }
      defer { self.recordingContext = recordingContext }

      let sampleTime = sampleBuffer.presentationTimeStamp
      guard sampleTime >= recordingContext.startTime else {
        print("^^^ skip sample because it's before recording start time")
        return
      }

      guard recordingContext.writerInput.isReadyForMoreMediaData else {
        print("^^^ skip sample because writer input is not ready")
        return
      }

      let relativeSampleTime = sampleTime - recordingContext.startTime
      let skipSample = sampleSkipTimeRange.contains(relativeSampleTime.seconds)
      if isSkippingSamples != skipSample {
        isSkippingSamples = skipSample
        if skipSample {
          print("^^^ start skipping samples at: \(relativeSampleTime.seconds)")
        } else {
          print("^^^ stop skipping samples at: \(relativeSampleTime.seconds)")
        }
      }
      guard !skipSample else { return }

      if recordingContext.firstSampleTime == nil {
        recordingContext.firstSampleTime = sampleTime
        print("^^^ first sample time: \((sampleTime - recordingContext.startTime).seconds)")
      }

      if let lastSampleTime = recordingContext.lastSampleTime,
         let lastSampleDuration = recordingContext.lastSampleDuration
      {
        let expectedSampleTime = lastSampleTime + lastSampleDuration
        let timeGap = sampleTime - expectedSampleTime
        if timeGap > .zero {
          print("^^^ detected gap with duration: \(timeGap.seconds)")
          print("^^^ current sample time: \((sampleTime - recordingContext.startTime).seconds)")
          print("^^^ expected sample time: \((expectedSampleTime - recordingContext.startTime).seconds)")

          if fillGaps {
            let sampleRate = Float64(expectedSampleTime.timescale)
            if let emptySampleBuffer = CMSampleBuffer.silentAudio(
              startFrame: expectedSampleTime.value,
              framesCount: Int(sampleRate * timeGap.seconds),
              sampleRate: sampleRate,
              channelsCount: 2
            ) {
              print("^^^ empty audio start: \((emptySampleBuffer.presentationTimeStamp - recordingContext.startTime).seconds)")
              print("^^^ empty audio duration: \(emptySampleBuffer.duration.seconds)")
              print("^^^ empty audio end: \((emptySampleBuffer.presentationTimeStamp + emptySampleBuffer.duration - recordingContext.startTime).seconds)")

              recordingContext.writerInput.append(emptySampleBuffer)
            } else {
              print("^^^ could not create empty sample buffer")
            }
          }
        }
      }

      recordingContext.lastSampleTime = sampleTime
      recordingContext.lastSampleDuration = sampleBuffer.duration
      recordingContext.writerInput.append(sampleBuffer)
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
    case kCMSampleBufferError_AllocationFailed: "AllocationFailed"
    case kCMSampleBufferError_RequiredParameterMissing: "RequiredParameterMissing"
    case kCMSampleBufferError_AlreadyHasDataBuffer: "AlreadyHasDataBuffer"
    case kCMSampleBufferError_BufferNotReady: "BufferNotReady"
    case kCMSampleBufferError_SampleIndexOutOfRange: "SampleIndexOutOfRange"
    case kCMSampleBufferError_BufferHasNoSampleSizes: "BufferHasNoSampleSizes"
    case kCMSampleBufferError_BufferHasNoSampleTimingInfo: "BufferHasNoSampleTimingInfo"
    case kCMSampleBufferError_ArrayTooSmall: "ArrayTooSmall"
    case kCMSampleBufferError_InvalidEntryCount: "InvalidEntryCount"
    case kCMSampleBufferError_CannotSubdivide: "CannotSubdivide"
    case kCMSampleBufferError_SampleTimingInfoInvalid: "SampleTimingInfoInvalid"
    case kCMSampleBufferError_InvalidMediaTypeForOperation: "InvalidMediaTypeForOperation"
    case kCMSampleBufferError_InvalidSampleData: "InvalidSampleData"
    case kCMSampleBufferError_InvalidMediaFormat: "InvalidMediaFormat"
    case kCMSampleBufferError_Invalidated: "Invalidated"
    case kCMSampleBufferError_DataFailed: "DataFailed"
    case kCMSampleBufferError_DataCanceled: "DataCanceled"
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
