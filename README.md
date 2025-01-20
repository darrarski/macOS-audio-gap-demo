# AudioGapDemo (macOS app)

![Swift v5.10](https://img.shields.io/badge/swift-v5.10-orange.svg)
![platform macOS](https://img.shields.io/badge/platform-macOS-blue.svg)

Example project for experimenting with audio recording on macOS and handling audio gaps.

## 📝 Description

AudioGapDemo is a macOS application built with Swift and SwiftUI that demonstrates how to capture audio using `AVCaptureSession` and handle audio gaps during recording. The app uses `AVAssetWriter` to write audio samples to a file and simulates gaps in the recording by skipping samples within a specified time range. This project is useful for understanding how to manage audio capture and processing in macOS applications.

More info about this approach for handling audio gaps can be found in the following article: [Handling audio capture gaps on macOS](https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos/) by Mathijs Kadijk and Tom Lokhorst.

> [!CAUTION]
> This project is a proof of concept and not production-ready. For known issues, please visit the [issue tracker](https://github.com/darrarski/macOS-audio-gap-demo/issues?q=is%3Aissue%20state%3Aopen).

## 🚀 Run

1. Open project in Xcode (≥16.2).
2. Change Developer Team and Bundle Identifier if needed.
3. Run the app using `AudioGapDemo` build scheme.

## ⚙️ Configuration

The `Recorder` class contains configuration options that can be adjusted to change the behavior of the audio recording:

- `deviceName`: The localized name of the capture device. Change this to use a different device.
- `sampleSkipTimeRange`: The range of time (in seconds) within samples should not be recorded (for gap simulation purposes).
- `fillGaps`: If `true`, the recorder will append empty samples to fill detected gaps.

These options can be found in the `Configuration` section of the `Recorder` class.

## ☕️ Do you like the project?

I would love to hear if you like my work. I can help you apply any of the solutions used in this repository in your app too! Feel free to reach out to me, or if you just want to say "thanks", you can buy me a coffee.

<a href="https://www.buymeacoffee.com/darrarski" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="60" width="217" style="height: 60px !important;width: 217px !important;" ></a>

## 📄 License

Copyright © 2025 [Dariusz Rybicki Darrarski](https://darrarski.pl)

[LICENSE](LICENSE)
