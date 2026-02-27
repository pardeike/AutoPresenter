# AutoPresenter Prototype (macOS)

Prototype macOS app that:

- loads a JSON presentation deck (`presentation.sample.json` schema)
- opens a Realtime API session over **WebRTC**
- streams microphone audio to the model
- injects current slide context into session instructions
- receives structured slide commands via function-calling events
- applies a local safety gate and logs accepted/rejected commands

This prototype intentionally **does not** actuate Keynote/PowerPoint yet.

## Requirements

- macOS 14+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- OpenAI API key with Realtime access

## Run

1. Export your API key:

```bash
export OPENAI_API_KEY='sk-...'
```

Alternatively, place it in `~/.api-keys`:

```json
{
  "OPENAI_API_KEY": "sk-..."
}
```

2. Generate and open the project:

```bash
xcodegen generate
open AutoPresenter.xcodeproj
```

3. Build and run target `AutoPresenter`.

4. In the app:

- verify API key and model (`gpt-realtime` default)
- load your deck JSON (or keep `presentation.sample.json`)
- click `Start Realtime`
- allow microphone permission when prompted
- speak through your rehearsal
- observe command decisions in `Command Log`

## Deck JSON format

The loader supports both:

- prototype schema (`presentation_title`, `slides[index/title/bullets/notes]`)
- richer schema (`deckTitle`, `slides[layout/title/speakerNotes/... ]`) as used in `/Users/ap/Projects/MeTube/documentation/presentation.json`

### Prototype schema

```json
{
  "presentation_title": "My Talk",
  "language": "en",
  "slides": [
    {
      "index": 1,
      "title": "Intro",
      "bullets": ["..."],
      "notes": "...",
      "keywords": ["..."]
    }
  ]
}
```

## Notes

- Realtime connection path:
  - app mints ephemeral `client_secret` via `POST /v1/realtime/client_secrets`
  - embedded WebRTC client posts SDP to `POST /v1/realtime/calls`
  - data channel receives events and function call arguments
- Command schema expected from model tool call:

```json
{
  "action": "next | previous | goto | stay",
  "target_slide": 3,
  "confidence": 0.84,
  "rationale": "brief reason",
  "utterance_excerpt": "optional excerpt"
}
```

- Safety gate checks:
  - JSON decoding/schema compatibility
  - confidence threshold
  - cooldown window
  - dwell confirmation
  - `goto` target validity within loaded deck

## Next step to reach full automation

Connect accepted commands to local actuation (AppleScript/key events) and feed back actual slide index from Keynote into `currentSlideIndex` context updates.
