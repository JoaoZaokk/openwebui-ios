# Third-Party Notices & Credits

**Open WebUI iOS** stands on the shoulders of these open-source projects, models,
and the Open WebUI server it talks to. Huge thanks to their authors. Their
licenses are preserved and apply to their respective components.

## The server it's a client for

This app is an **unofficial native client** for [Open WebUI](https://github.com/open-webui/open-webui)
(© Open WebUI contributors), the self-hosted AI interface. It talks to a standard
Open WebUI instance over its REST + OpenAI-compatible API. Open WebUI is released
under its own license — see its repository. This project is **not affiliated with
or endorsed by** the Open WebUI project.

## Swift packages (dependencies)

| Project | Author | License | Use |
|---|---|---|---|
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | Guillermo Gonzalez | MIT | Markdown rendering in chat bubbles |
| [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) | exPHAT | MIT | Swift wrapper for whisper.cpp (STT) |
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | Georgi Gerganov | MIT | On-device speech recognition engine |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | Thomas Zoechling | MIT | Unzipping downloaded CoreML encoders |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | FluidInference | Apache-2.0 | PocketTTS neural text-to-speech |

## Models (downloaded on-device at runtime, not bundled)

| Model | Source | License | Use |
|---|---|---|---|
| Whisper (ggml/GGUF + CoreML encoders) | OpenAI, packaged by [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | MIT | On-device speech-to-text |
| [PocketTTS](https://huggingface.co/FluidInference/pocket-tts-coreml) | FluidInference | **CC-BY-4.0** (attribution required) | Neural text-to-speech (pt-BR & more) |
| [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | hexgrad | Apache-2.0 | Upstream model PocketTTS is based on |

> **PocketTTS is CC-BY-4.0** — attribution to **FluidInference** (and upstream
> **Kokoro / hexgrad**) is required wherever its audio output or the model is used.

Server-side speech (the "Servidor" STT/TTS options) is provided by whatever engine
the user's Open WebUI instance is configured with (e.g. OpenAI-compatible
`/audio/speech` & `/audio/transcriptions`).

## Fonts

| Font | Author | License | Use |
|---|---|---|---|
| [Inter](https://github.com/rsms/inter) | Rasmus Andersson | SIL Open Font License 1.1 | The "Anthropic Sans" theme typeface (bundled `Inter.ttf`) |

Other typefaces are the Apple system fonts (SF Pro / SF Mono / New York /
SF Rounded) used via `Font.Design`.

## Apple frameworks

SwiftUI, AVFoundation (`AVSpeechSynthesizer`, `AVAudioEngine`, voice-processing
AEC), the Speech framework (`SFSpeechRecognizer`), CoreML, UIKit and PhotosUI —
© Apple Inc., used under the iOS SDK terms.

## Build tooling

[XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT) generates the Xcode
project from `project.yml`.

## Trademarks & brand assets

The app ships a multi-theme "skin" system. The names, logos and marks of
**Anthropic / Claude**, **OpenAI / ChatGPT / Codex**, **Google / Gemini**,
**Open WebUI**, and **Nous Research / Hermes** are trademarks of their respective
owners. They are included **only** to theme this personal client to resemble each
product and imply **no affiliation, sponsorship, or endorsement**. All rights to
those marks remain with their owners; remove or replace them if you redistribute.
The "Odysseus" sail icon is reused from the author's own [odysseus-ios](https://github.com/JoaoZaokk/odysseus-ios).

---

If you redistribute this app or build on it, keep this file and the upstream
license notices intact.
