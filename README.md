# Claude Code Notifier

A macOS menu bar app. When a Claude Code session needs you or finishes its turn, the app tells you.

| Situation | Notification | Menu bar |
|---|---|---|
| Claude asks you: a permission, a question (`AskUserQuestion`) or a plan approval (`ExitPlanMode`) | »Claude asks you« | An orange bubble that rings every 20 s, with the sound »Pop« |
| Claude finished its turn, and the prompt is open | »Your turn«, with the start of Claude's last message | The wave stops |

The notifications make no sound. The ring of the bubble is the only sound of the app. The sound stops after 5 minutes
without an answer, and it plays again after a session starts to work. While a Focus of macOS is on, the app plays no
sound.

- **Menu bar icon:** always 58 pt wide, so the menu bar never shifts. While sessions work, a pale green wave with a
  dark green segment that runs along it from left to right. Core Animation moves the segment, so the app does no work
  per frame. From two working sessions on, their number stands right of the wave. Sessions that ask you add an orange
  speech bubble at the right end, with their number from two sessions on. The bubble has the highest priority: it
  pops in, and every 20 s it rings twice. It swings, grows and glows dark red, a halo pings behind it, and the wave
  glows dark red with it. To make room, the wave keeps its wavelength and gets shorter. Without work, the same wave
  stands still in the menu bar color. When work starts, the green wave grows in from the left, and the segment enters
  at the left end. When work ends, the green wave leaves to the right, and the segment leaves with it. A gap in the still wave means that the setup has a problem.
- **Menu:** a card with one row per session: a colored state icon, the session title, and the running time since
  the start on the right. The time shows as »58s« in the first minute and as a clock like »4:07« in the first hour.
  After that, it shows as »1h 09m«, and from one day on as »2d 4h 03m«. The title is the one that the Claude Code
  extension shows: an agent name, a title from a rename, the title that Claude made, or the first prompt. The app
  reads it from the end of the transcript. While the menu is open, the time updates every second. Sessions that ask
  you come first, then the working ones, then the finished ones. A row is highlighted under the mouse pointer, but
  the card only shows information, it cannot be clicked. Archived sessions are not in the card.
- **Notifications:** one per session, with the session title. A newer one replaces the older one. A click brings VS
  Code to the front.
- **Menu:** three groups. First the card, with the app status on the right of its header (»Listening on
  127.0.0.1:47823«, or a problem in orange). Then »Notifications«: show notifications, when it is your turn, and
  test notifications for each situation. Then »Sounds«: »Play Sounds« turns off every sound of the app. Last »Launch at Login«, »Hook Setup …« and »Quit«.

## How it works

Claude Code hooks send each event with `curl` to `http://127.0.0.1:47823/event`. The hook command ignores proxies and
`~/.curlrc`, so the event goes only to the app. The app listens only on the loopback interface, and it accepts only
requests with the header `X-Claude-Hook`. It refuses requests from web pages: requests with an `Origin` header or with
a host name other than `localhost`. While the app is not running, the hook fails silently after at most 1 s. Claude
Code is not affected.

| Hook | State |
|---|---|
| `SessionStart` | your turn (no notification) |
| `UserPromptSubmit`, `PostToolUse` | working |
| `PreToolUse` with the matcher `AskUserQuestion\|ExitPlanMode` | asks you → notification at once |
| `Notification` | asks you → notification, unless a question or plan reported it already. After a finished turn, the idle reminder sends no notification. |
| `Stop` | your turn → notification |
| `StopFailure` (an API error ended the turn) | your turn → notification with the error |
| `SessionEnd` | ended, without a notification, because you close a session yourself. An archived session leaves the menu (see below). With the reason `clear`, the session just disappears. |

When you interrupt Claude, Claude Code runs no hook. It only writes the marker `[Request interrupted by user]` into
the transcript. So every 3 s, the app reads the end of the transcript of each working session. When the last message
is this marker, the app sets the session to »your turn«.

The VS Code extension keeps the IDs of archived sessions in its global state, under `hiddenSessionIds`. The app reads
this list from the SQLite database of VS Code, read-only. Every 3 s, it removes the archived sessions from the menu,
while they run or after they ended.

Claude Code writes one file per running session process into `~/.claude/sessions`. The file holds the session ID, the
folder, the start time and a status (`busy`, `waiting` or `idle`). At its start and every 3 s, the app reads these
files. It adds running sessions that it does not know yet, so the card also shows sessions that started before the
app. The clocks count from the real start. When a file has a newer status than the last hook event, the app follows
it. This keeps sessions without hooks up to date. A session whose process ended without a `SessionEnd` hook becomes
»ended«. None of this sends a notification.

A session can start a shell command in the background and end its turn. Claude Code runs every shell command of a
session as a child of the session process, with a shell snapshot from `~/.claude/shell-snapshots`. Every 3 s, the app
counts these commands for each session. A session whose turn is over but that still runs such a command counts as
working. The card shows a gray hourglass with a blue badge for it, and the spinner counts it. The »Your turn«
notification at the end of the turn stays. A command that never ends, for example a dev server, keeps the session
»working«. The session stays »working« until the command stops.

Claude Code sends the `Notification` for a permission prompt only 6 s after the prompt appears. So a permission that
you answer quickly gives no notification.

## Setup

1. Move `build/Claude Code Notifier.app` to `/Applications` or `~/Applications`, and open it. Allow notifications.
2. The setup window opens and checks four things. While the window is open, the checks update:
   1. The app listens on `127.0.0.1:47823`.
   2. `~/.claude/settings.json` has a hook for each of the eight events. The window shows the block to add. Without a
      settings file, it shows the whole file. A button copies the text. The app only reads the file, it never
      changes it.
   3. The hook command reaches the app: the app runs the configured command with a test event and waits for it.
   4. An event from Claude Code arrived after the app started. At the start of a session, Claude Code reads the
      hooks. So restart the sessions that are open.
3. Start at login: System Settings › General › Login Items › »+« › choose the app. Or use »Launch at Login« in the menu.
   Do this only after step 1, because the entry points to the current location of the app.

At every start, the window opens until the first three checks pass and notifications are allowed. Later, a gap in the
wave in the menu bar shows that the hooks stopped working. Then »Hook Setup …« in the menu opens the window again. Like
Claude Code, the app honors `CLAUDE_CONFIG_DIR`.

## Files on your Mac

The app leaves as few files as possible outside its bundle:

- `~/Library/Preferences/local.claude-code-notifier.app.plist` exists only after you change a setting in the menu or
  move the icon in the menu bar. The app stores only the settings that differ from the default.
- macOS keeps the notification permission, the login item and an empty Metal cache folder for the app.
- The app only reads `~/.claude` and the VS Code database. It writes no logs and no caches.

To remove the app, delete it, then delete the settings file with `rm`. Do not use `defaults delete`, because it leaves
an empty file.

## Build

```bash
npm run start
```

`npm run build` runs `build.sh`, and `npm run restart` stops the running app and opens the new build. `npm run start`
does both. The scripts need no npm packages.

The build needs only the Xcode Command Line Tools. The script first runs the unit tests in `Tests/` with `swift
test`. If a test fails, the script stops. The build files, caches and temporary files stay in `build/` and `.build/`.
Only the shared caches of the Xcode tools change outside the project. `make-icon.swift` draws the app icon. The newest SDK of the Command Line Tools can be newer than their
compiler, so the script uses the macOS 26 SDK. To use another SDK, set `SDK=<path>`.

## Limits

- Every user account on the Mac can reach `127.0.0.1:47823`. Another account can send fake events. While the app does
  not run, another account can also take the port and receive the hook data of your sessions, for example your
  prompts. On a Mac with one user, this does not matter.

- A click on a notification brings VS Code to the front, but not the window of the session. If a window shows
  exactly the folder of the session, VS Code focuses it. For a folder inside a `.code-workspace`, VS Code opens a new
  window instead. To raise one window from outside, an app needs the Accessibility permission.
