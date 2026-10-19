# Claude Code Notifier

A macOS menu bar app. It tells you when a Claude Code session needs you, has finished, or has ended.

| Situation | Notification | Sound |
|---|---|---|
| Claude asks you: a permission, a question (`AskUserQuestion`) or a plan approval (`ExitPlanMode`) | »Claude asks you« | Purr |
| Claude has finished its turn, and the prompt is open | »Your turn«, with the start of Claude's last message | Bottle |
| The session was closed (`/clear` and archiving do not count) | »Session ended« | Pop |

- **Menu bar icon:** a bell while nothing happens. While sessions work, an orange spinner: an arc that turns around a ring,
  with a sparkle in the middle for one session, or the number of working sessions. A bell with a count while sessions
  ask you something, because that needs you first. A crossed-out bell means that the setup has a problem.
- **Menu:** a card with one row per session: a colored state icon, the project, the state, and the running time since
  the start on the right (»4:07«, »1:04:07«). The time updates every second while the menu is open. The card only
  shows information, it cannot be clicked. Archived sessions are not in the card.
- **Notifications:** one per session. A newer one replaces the older one. A click brings VS Code to the front.
- **Settings in the menu:** notify when it is your turn, notify when a session ends, play sound, mute all,
  launch at login, and test notifications for each situation.

## How it works

Claude Code hooks send each event with `curl` to `http://127.0.0.1:47823/event`. The app listens only on the loopback
interface, and it accepts only requests with the header `X-Claude-Hook`. If the app is not running, the hook fails
silently after at most 1 s, and Claude Code is not affected.

| Hook | State |
|---|---|
| `SessionStart` | your turn (no notification) |
| `UserPromptSubmit`, `PostToolUse` | working |
| `PreToolUse` with the matcher `AskUserQuestion\|ExitPlanMode` | asks you → notification at once |
| `Notification` | asks you → notification, unless a question or plan reported it already. The idle reminder only notifies if no notification came before. |
| `Stop` | your turn → notification |
| `StopFailure` (an API error ended the turn) | your turn → notification with the error |
| `SessionEnd` | ended → notification after 2 s. An archived session leaves the menu without a notification (see below). With the reason `clear`, the session just disappears. |

Claude Code runs no hook when you interrupt Claude. It only writes the marker `[Request interrupted by user]` into the
transcript. So every 3 s, the app reads the end of the transcript of each working session, and sets the session to
»your turn« when the last message is this marker.

The VS Code extension keeps the IDs of archived sessions in its global state, under `hiddenSessionIds`. The app reads
this list from the SQLite database of VS Code, read-only. When a session ends, the app waits 2 s for VS Code to write
the list. An archived session leaves the menu without a notification, because you archived it yourself. The 3 s check
also removes a session that you archive later, while it runs or after it ended.

Claude Code sends the `Notification` for a permission prompt only 6 s after the prompt appears. So a permission you
answer quickly gives no notification.

## Setup

1. Move `build/Claude Code Notifier.app` to `/Applications` or `~/Applications`, and open it. Allow notifications.
2. The setup window opens and checks four things. It updates while it is open:
   1. The app listens on `127.0.0.1:47823`.
   2. `~/.claude/settings.json` has a hook for each of the eight events. The window shows the block to add, or the whole
      file if there is none yet, with a button to copy it. The app only reads the file, it never changes it.
   3. The hook command reaches the app: the app runs the configured command with a test event and waits for it.
   4. An event from Claude Code arrived. Claude Code reads the hooks when a session starts, so restart open sessions.
3. Start at login: System Settings › General › Login Items › »+« › choose the app. Or use »Launch at Login« in the menu
   (only after step 1, because the entry points to the current location of the app).

The window opens at every start until the setup is complete. Later, a crossed-out bell in the menu bar shows that the
hooks stopped working, and »Hook Setup …« in the menu opens the window again. The app honors `CLAUDE_CONFIG_DIR` like
Claude Code does.

## Build

```bash
./build.sh
```

Needs only the Xcode Command Line Tools. `make-icon.swift` draws the app icon, and the sounds are copied from
`/System/Library/Sounds`. The script uses the macOS 26 SDK, because the newest SDK of the Command Line
Tools can be newer than their compiler. Set `SDK=<path>` to use another one.

## Limits

- The app keeps the sessions only in memory. After a restart of the app, a session appears again with its next event.
- A click on a notification brings VS Code to the front, but not the window of the session. Opening the session's
  folder in VS Code would focus its window only if the window shows exactly this folder. For a folder inside a
  `.code-workspace`, VS Code opens a new window instead. Raising one window from outside needs the Accessibility
  permission.
- The running time counts from the first event the app saw. For a session that ran before the app started,
  that is later than the real start.
