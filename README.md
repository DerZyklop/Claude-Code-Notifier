# Claude Code Notifier

A macOS menu bar app. It tells you when a Claude Code session needs you or has finished.

| Situation | Notification | Sound |
|---|---|---|
| Claude asks you: a permission, a question (`AskUserQuestion`) or a plan approval (`ExitPlanMode`) | »Claude asks you« | Purr |
| Claude has finished its turn, and the prompt is open | »Your turn«, with the start of Claude's last message | Bottle |

- **Menu bar icon:** a sparkle while no session works. While sessions work, a spinner: an orange arc that turns
  around a faint orange ring, with a sparkle in the middle for one session, or the number of working sessions. Core
  Animation turns the arc, so the app does no work per frame. Sessions that ask you add an orange speech bubble with
  their count inside it, so a forgotten prompt does not hide the work in other sessions. A crossed-out sparkle means
  that the setup has a problem.
- **Menu:** a card with one row per session: a colored state icon, the session title, the state, and the running time
  since the start on the right (»58s« in the first minute, a clock for the first hour like »4:07«, then »1h 09m«, then »2d 4h 03m«). The title is the one that the Claude Code extension shows: an agent
  name, a title from a rename, the title that Claude made, or the first prompt. The app reads it from the end of the
  transcript. The time updates every second while the menu is open. A row is highlighted under the mouse pointer, but
  the card only shows information, it cannot be clicked. Archived sessions are not in the card.
- **Notifications:** one per session, with the session title. A newer one replaces the older one. A click brings VS Code to the front.
- **Menu:** three groups. First the card, with the app status on the right of its header (»Listening on
  127.0.0.1:47823«, or a problem in orange). Then »Notifications«: when it is your turn, play
  sound, mute all, and test notifications for each situation. Last »Launch at Login«, »Hook Setup …« and »Quit«.

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
| `SessionEnd` | ended, without a notification, because you close a session yourself. An archived session leaves the menu (see below). With the reason `clear`, the session just disappears. |

Claude Code runs no hook when you interrupt Claude. It only writes the marker `[Request interrupted by user]` into the
transcript. So every 3 s, the app reads the end of the transcript of each working session, and sets the session to
»your turn« when the last message is this marker.

The VS Code extension keeps the IDs of archived sessions in its global state, under `hiddenSessionIds`. The app reads
this list from the SQLite database of VS Code, read-only. Every 3 s, it removes the archived sessions from the menu,
while they run or after they ended.

Claude Code writes one file per running session process into `~/.claude/sessions`, with the session ID, the folder,
the start time and a status (`busy`, `waiting` or `idle`). Every 3 s, and when it starts, the app reads these files.
It adds running sessions that it does not know yet, so the card also shows sessions that started before the app. The
clocks count from the real start. When a file has a newer status than the last hook event, the app follows it, which
keeps sessions without hooks up to date. A session whose process ended without a `SessionEnd` hook becomes »ended«.
None of this sends a notification.

A session can start a shell command in the background and end its turn. Claude Code runs every shell command of a
session as a child of the session process, with a shell snapshot from `~/.claude/shell-snapshots`. Every 3 s, the app
counts these commands for each session. A session whose turn is over but that still runs such a command counts as
working: the card shows »background task« with a terminal icon, and the spinner counts it. The »Your turn« notification at the end of the
turn stays. A command that never ends, for example a dev server, keeps the session »working« until the command stops.

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

The window opens at every start until the setup is complete. Later, a crossed-out sparkle in the menu bar shows that the
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

- A click on a notification brings VS Code to the front, but not the window of the session. Opening the session's
  folder in VS Code would focus its window only if the window shows exactly this folder. For a folder inside a
  `.code-workspace`, VS Code opens a new window instead. Raising one window from outside needs the Accessibility
  permission.
