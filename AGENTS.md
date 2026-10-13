# PromptShelf-Open

This is a native macOS AppKit app with no account, payment, or hosted database dependency.

- Keep the bundle ID, Application Support directory, preferences and Keychain service distinct from PromptShelf.
- Never modify the original PromptShelf checkout or installed app as part of this project.
- Never publish credentials, private configuration, prompt history, user libraries or personal execution records.
- Model calls, document extraction and workflow persistence must stay off the main thread. AppKit changes stay on the main thread.
- Workflow saves use immutable snapshots, ordered revisions, visible errors and a verified shutdown flush.
- Never write to a user-selected document without showing the proposed content and obtaining explicit confirmation. Reject writes when the target changed after preview.
- Use isolated preferences, named pasteboards and synthetic file/library fixtures for verification. Track and close only test instances started for the task.
- Compare performance with the same data and operations. CPU timings do not establish desktop input latency or frame rate.
- Verify Chinese composition, selection, undo, scrolling, dragging and resizing on the desktop; state any remaining gap.
- Real model acceptance must use a running model, not mocked responses. Keep protocol/error fixtures separate from real model results.

Build: `./build.sh`. Checks: `scripts/verify.sh`. Release packaging: `scripts/package.sh`.
