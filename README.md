# AutoPresenter (Prototype)

AutoPresenter is a macOS prototype for AI-assisted presentation rehearsal.
It listens while you speak, keeps the model grounded on the current slide, and interprets structured Realtime commands for highlighting and navigation.

The project is intentionally still in prototype mode: no production-grade Keynote/PowerPoint actuation flow yet.

## What You Get

- Realtime speech session via WebRTC (`gpt-realtime` by default)
- JSON deck loading with multiple slide layouts
- Presenter window + main control window
- In-app slide editor with drag reorder, add/delete, and save
- Local command safety gate before any command is accepted
- Activity and command logging (including mirrored runtime log file)

## Requirements

- macOS 14+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- OpenAI API key with Realtime access

Install XcodeGen:

```bash
brew install xcodegen
```

## Quick Start

1. Set API key:

```bash
export OPENAI_API_KEY='sk-...'
```

or create `~/.api-keys`:

```json
{
  "OPENAI_API_KEY": "sk-..."
}
```

2. Generate project and open it:

```bash
xcodegen generate
open AutoPresenter.xcodeproj
```

3. Build and run target `AutoPresenter`.

4. In the app:
- Open a deck (`File > Open…`)
- Start recording (`File > Start Recording` or `Cmd+R`)
- Open presentation window (`File > Show Presentation` or `Cmd+P`)
- Speak through your talk and monitor decisions in the activity feed

## Deck JSON Support

The loader accepts both a simple prototype schema and a richer schema with layouts.
Unknown/extra fields are tolerated.

### Simple schema

```json
{
  "presentation_title": "My Talk",
  "language": "en",
  "slides": [
    {
      "index": 1,
      "title": "Intro",
      "bullets": ["Point A", "Point B"]
    }
  ]
}
```

### Rich schema (core fields)

```json
{
  "deckTitle": ["My Talk"],
  "slides": [
    {
      "layout": "bullets",
      "title": ["Slide title"],
      "subtitle": ["Optional subtitle"],
      "bullets": ["One", "Two"]
    }
  ]
}
```

Supported layouts:
- `title`
- `bullets`
- `quote`
- `image`
- `twoColumn`

## Command Pipeline (Realtime)

Expected model tool payload:

```json
{
  "commands": [
    {
      "action": "mark | next | previous | goto | stay",
      "target_slide": null,
      "mark_index": 2,
      "confidence": 0.84,
      "rationale": "brief factual reason",
      "utterance_excerpt": "optional excerpt",
      "highlight_phrases": ["exact phrase from slide"]
    }
  ]
}
```

Safety gate validates:
- command shape / compatibility
- confidence threshold
- cooldown and dwell windows
- navigation target validity

Realtime timing is configurable in app Settings:
- `Commit Interval (ms)` controls how often client-side audio chunks are committed in manual mode
- `Max Output Tokens` limits model response size for faster function-call completion
- `Mark Cooldown (ms)` enforces a minimum delay between accepted mark actions

## Keyboard Shortcuts

- `Cmd+O` Open deck
- `Cmd+S` Save
- `Cmd+Shift+S` Save As…
- `Cmd+E` Open editor
- `Cmd+P` Show/Hide presentation window
- `Cmd+R` Start/Stop recording
- `Cmd+F` Toggle fullscreen
- `Cmd+Return` Save slide draft in editor

## Runtime Logs

- Mirrored command log file: `runtime/command-log.txt`
- File is truncated on app startup, then appended for the current session

## Project Status

Current focus:
- Realtime command pipeline quality
- window/editor UX
- robust in-memory deck editing and persistence

Not in scope yet:
- full production presenter actuation
- integrated finalized fullscreen presenter product flow

## License

MIT. See [LICENSE](LICENSE).
