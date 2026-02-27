# AutoPresenter Agent Notes

## Current Scope (Prototype)

- Keep the app in prototype mode.
- Continue using the Realtime command pipeline with local safety gate.
- Do not implement production-grade presenter/fullscreen execution flow yet.
- Keep actuation behavior at log/decision level unless explicitly requested.

## Roadmap (Future, Not In Scope Yet)

1. Build a fully integrated presenter app (no Keynote/PowerPoint dependency).
2. Add a dedicated fullscreen Present Mode window for rendered slide content.
3. Support visual coverage tracking in Present Mode (for example, bullet lines recolored as they are covered).
4. Extend model command schema for semantic coverage updates tied to currently visible content.
5. Close the loop with robust state sync between spoken content, slide state, and rendered coverage UI.

## Runtime Logs

- App command logs are mirrored to `./runtime/command-log.txt` in the repository root.
- The file is truncated on app startup, then new session entries are appended.
