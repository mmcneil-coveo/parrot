import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self, DictionaryCheck.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(name: .long, help: "Hotkey to use: fn (default), right-command, right-option.")
    var hotkey: String = "fn"

    @Flag(name: .long, help: "Tap the hotkey once to start, again to stop (default: hold).")
    var toggle: Bool = false

    @Flag(name: .long, help: "Also copy each transcript to the clipboard.")
    var copy: Bool = false

    @Option(name: .long, help: "Word-replacement dictionary (default: ~/.config/parrot/dictionary.json).")
    var dictionary: String?

    func run() throws {
        guard let hotkeyTarget = HotkeyTarget(rawValue: hotkey) else {
            FileHandle.standardError.write(Data("unknown hotkey: \(hotkey)\n".utf8))
            FileHandle.standardError.write(Data("valid options: fn, right-command, right-option\n".utf8))
            throw ExitCode(1)
        }

        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriber = WhisperKitTranscriber(model: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(target: hotkeyTarget, debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated { MenuBarController(modelID: chosenModel.id) }
        let toggleMode = self.toggle
        let copyToClipboard = self.copy
        var isRecording = false

        // A bad dictionary must never take dictation offline — warn and run
        // without replacements.
        let dictPath = dictionary ?? ReplacementDictionary.defaultPath
        var replacements = ReplacementDictionary.empty
        do {
            if let loaded = try ReplacementDictionary.load(path: dictPath) {
                replacements = loaded
            }
        } catch {
            FileHandle.standardError.write(Data(
                "warning: ignoring \(dictPath) — \(error)\n".utf8
            ))
            FileHandle.standardError.write(Data("run `parrot dictionary` to check it\n".utf8))
        }

        func beginRecording() {
            do {
                try capture.start()
                isRecording = true
                FileHandle.standardError.write(Data("● recording\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.show(.recording)
                    menuBar.setRecording(true)
                }
            } catch {
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            }
        }

        func endRecordingAndTranscribe() {
            isRecording = false
            let samples = capture.stop()
            MainActor.assumeIsolated {
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
            }
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            let rms = computeRMS(samples)
            FileHandle.standardError.write(Data(
                String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
            ))
            if dumpWav, !samples.isEmpty {
                let path = "/tmp/parrot-last.wav"
                do {
                    try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                    FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                }
            }
            guard !samples.isEmpty else {
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                }
                return
            }
            Task {
                let started = Date()
                do {
                    let raw = try await transcriber.transcribe(samples)
                    let text = replacements.apply(to: raw)
                    let elapsed = Date().timeIntervalSince(started)
                    FileHandle.standardError.write(Data(
                        String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                    ))
                    await MainActor.run {
                        if copyToClipboard {
                            Clipboard.copy(text)
                        }
                        TextInjector.inject(text)
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                } catch {
                    FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                    await MainActor.run {
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                }
            }
        }

        do {
            try monitor.start { event in
                if toggleMode {
                    // Only the physical key-down edge matters; each tap flips
                    // between recording and transcribing.
                    guard case .pressed = event else { return }
                    if isRecording {
                        endRecordingAndTranscribe()
                    } else {
                        beginRecording()
                    }
                    return
                }
                switch event {
                case .pressed:
                    beginRecording()
                case .released:
                    endRecordingAndTranscribe()
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let modeLabel = toggleMode ? "toggle" : "hold"
        let copyLabel = copyToClipboard ? " · copying to clipboard" : ""
        let dictLabel = replacements.count > 0 ? " · \(replacements.count) replacements" : ""
        FileHandle.standardError.write(Data("listening on \(hotkeyTarget.rawValue) \(modeLabel) · model: \(chosenModel.id)\(copyLabel)\(dictLabel) · ^C to quit\n".utf8))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}

/// `parrot dictionary` — check the replacement file and report what loaded.
/// Exists because the daemon only warns about a bad file in its log, which is
/// easy to miss; this gives a plain answer on demand.
struct DictionaryCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictionary",
        abstract: "Check the word-replacement dictionary."
    )

    @Option(name: .long, help: "Path to check (default: ~/.config/parrot/dictionary.json).")
    var path: String?

    @Option(name: .long, help: "Show what a sample phrase would become.")
    var test: String?

    func run() throws {
        let target = path ?? ReplacementDictionary.defaultPath

        let dict: ReplacementDictionary
        do {
            guard let loaded = try ReplacementDictionary.load(path: target) else {
                print("no dictionary at \(target)")
                print("(that's fine — replacements are optional)")
                return
            }
            dict = loaded
        } catch {
            print("✗ \(target)")
            print("  \(error)")
            print()
            print("parrot will keep running and skip replacements until this is fixed.")
            throw ExitCode(1)
        }

        print("✓ \(target)")
        print("  \(dict.count) replacements loaded")

        if let test {
            let result = dict.apply(to: test)
            print()
            print("  in:  \(test)")
            print("  out: \(result)")
        }
    }
}
