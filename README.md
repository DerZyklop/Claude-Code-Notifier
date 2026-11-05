# Claude Code Pulse

A macOS menu bar app. When a Claude Code session needs you or finishes its turn, the app tells you.

![The menu of the app, with two sessions](assets/screenshot.png)

## What you see

| Situation | Menu bar | Notification |
|---|---|---|
| Claude works | A green wave with a moving segment | None |
| A report runs | The wave is purple | None |
| Claude asks you (permission, question, plan approval) | An orange bubble that rings every 20 s | »Claude asks you« |
| Claude finished its turn | The wave stops | »Your turn«, with the start of the last message |
| The setup has a problem | A gap in the wave | None |

- **Menu bar icon:** always 70 pt wide. With two or more sessions, the icon shows their number, for example »×2«.
- **Card:** one row for each session, with its state, title and running time. Sessions that ask you come first.
  Archived sessions are not in the card.
- **Notifications:** one for each session. A newer one replaces the older one. A click brings VS Code to the front.
- **Sound:** only the ring of the bubble. It stops after 5 minutes without an answer. It does not play while a macOS
  Focus is on. »Play Sounds« in the menu turns it off.

## Morning overview

The app writes `morning-overview.md` into the project folder `~/S/plano`. The file is a short list of open tasks in
six sections: the open PRs of others, my open PRs, draft PRs, the tickets of the sprint, open branches and other
work. »Open branches« lists only the local branches that no listed PR or ticket covers. In each section, the easiest
tasks come first. Each task has a title line with the links of the PR and the ticket and a short title. Below it,
each next action is a sub-item with a checkbox. A sub-item without a checkbox is no task and gets no ID. The app adds the file to `.git/info/exclude`, so git never stages it.

- **When:** the first start, wake or unlock on a weekday from 6:00 on, or a check every 15 minutes. A file updated
  today from 6:00 on skips the run. »Update Now« in the menu starts a run at any time. »Every Weekday at 6:00« turns
  the daily run off.
- **Done:** a notification says how many tasks are open. A click on it opens the file in Obsidian, or in VS Code without Obsidian. Until you open
  the file, the menu shows a purple dot behind »Open Morning Overview«, and the menu bar shows one left of the wave. A failure always gets a notification, and the menu shows its reason.
- **Sources:**
  - The old file. Done tasks leave it.
  - The open PRs on Bitbucket, with their open tasks and newest comments. The repo comes from the remote `origin`.
  - The PRs of other devs that were merged since the last overview, that change `scheduler.frontend.ng2/`, and that
    I did not approve or send back. The app writes them into »Other Devs' Merges« near the end, without Claude. An
    open task stays in the next overview. A ticked task leaves it.
  - The Jira tickets of the open sprint, from the Atlassian MCP in the `.mcp.json` of the project. »Cleanup Work«
    also lists your tickets that are »In Progress« or »Untested« and in no sprint.
  - Untracked plan files, uncommitted and unpushed work in every worktree, the plans in `~/.claude/plans`, the Claude
    memory of the project and the titles of recent sessions.

The prompt is `Resources/morning-overview-prompt.md`. The app fetches the PRs itself, with GET requests only. For this,
the login shell must set `BITBUCKET_API_EMAIL` and `BITBUCKET_API_TOKEN`. Then the app runs `claude -p` through the
login shell, and Claude only reads:

- `--tools Read,Grep,Glob,Bash` leaves out every tool that writes.
- `--restricted` ignores the settings files, so their allow rules do not apply.
- `--permission-mode dontAsk` refuses every call that is not on the allow list, without a prompt. Only the Jira read
  tools are on it. Bash runs only the commands that Claude Code knows as read-only, for example `git status`.

Claude prints the overview, and the app writes the file. The run never gets `BITBUCKET_API_TOKEN` or `SLACK_USER_TOKEN`.
If a Bitbucket request fails, the run fails without writing an overview. This includes the request for the details of
one PR. So missing PR data cannot look like a successful update.

## Usage of your accounts

Below the sessions, a second card shows the limits of each Claude account: the 5-hour limit and the weekly limit, each
with its reset time. From 80 % on, the percentage is orange.

- **Accounts:** the default folder `~/.claude`, and each folder `~/.claude-*` with a `.claude.json` in it.
- **Add an account:** click »Accounts …« in the card, then »Add Account …«. The app creates the folder
  `~/.claude-account-<n>` and runs `claude auth login` for it, which opens the login page of Claude. The page decides
  the account. If the account is in the list already, the app logs
  out of the new folder and deletes it. An account without a login gets »Log In«.
- **Remove an account:** the minus button in the Accounts tab. For a folder that the app created, the app logs out and
  deletes the folder. Any other folder, for example `~/.claude`, only leaves the list.
- **How:** the app runs `claude -p` with a prompt of one token for each account, and reads the limits from its
  output. The app never reads a login token. The run skips all hooks, so it does not show as a session.
- **When:** when you open the menu and the data is older than 10 minutes, or when you click the arrow in the card.
- **Cost:** each update uses a little of the 5-hour limit. On an idle account, it starts the 5-hour window.
- **Remove:** delete `Sources/AccountUsage.swift`, `Sources/AccountUsageCard.swift`, `Sources/AccountsView.swift`
  and `Tests/AccountUsageTests.swift`. Then remove `addUsageCard(to:)` in `Sources/StatusMenu.swift` and the tab
  `SetupTab.accounts` in `Sources/HookSetup.swift`.

## DiDi

The app writes `didi.md` into the same folder: the summary of the current sprint. A sprint starts on Tuesday at 11:00.
The file has three sections:

- **Merges:** each PR that you wrote and that was merged in the sprint. The title line starts with the emoji of its
  kind: ✨ feature, 👌 improvement, 🐛 bugfix, ⚡️ performance, 🧹 maintenance, 🧪 tests, 📝 docs. Then it has the
  links of the PR and the ticket, as in the morning overview. Up to 3 highlights from the description and the review
  comments are its sub-items. The Jira site of the ticket link comes from the morning overview.
- **Slack:** up to 10 special things from the Slack messages of the sprint, in channels and in DMs. Each one links to
  its message.
- **Notes:** your own text. Each run keeps it. In a file that the app did not write, all text below the title counts as
  notes.

- **When:** the first start, wake or unlock on a Tuesday from 6:00 on. A run before 11:00 covers the full sprint of the
  last week. »Update Now« covers the current sprint until now.
- **Backup:** before each write, the app copies the old file to
  `~/Library/Application Support/local.claude-code-notifier.app/didi/`, one file for each sprint.
- **Safety:** the app fetches all data with GET requests. Claude gets no tool and no MCP server, runs in an empty
  folder, and only answers in a fixed JSON shape. The app writes each line of the file itself. It refuses an answer
  that names a PR or a Slack message that is not in the data.

The prompt is `Resources/didi-prompt.md`. For Slack, the login shell must set `SLACK_USER_TOKEN`. Without it, the
update fails and does not change the file. To get the token:

1. On api.slack.com/apps, create an app »From scratch« in your workspace.
2. Add the User Token Scopes `search:read`, `users:read`, `channels:read`, `groups:read`, `im:read` and `mpim:read`.
3. Install the app in the workspace. A workspace admin can have to approve it.
4. Put `export SLACK_USER_TOKEN=xoxp-…` into `~/.zprofile`, next to the `BITBUCKET_API_*` variables. The app reads the
   login shell, which does not read `~/.zshrc`.

## Setup

1. Move `build/Claude Code Pulse.app` to `/Applications` or `~/Applications`.
2. Open the app, and allow notifications.
3. Follow the setup window. It shows the hook block to add to `~/.claude/settings.json`, with a copy button. The app
   never changes this file.
4. Restart the open Claude Code sessions. Claude Code reads the hooks only at the start of a session.
5. Optional: select »Launch at Login« in the menu.
6. Optional: run `npm run install-extension`, and reload VS Code. The extension in `vscode-extension/` tells the app
   which Claude tab you look at. The app then closes the notifications of that session, and sends none for it while
   the tab stays in front. This only works for a Claude tab in the editor area, not for Claude in the sidebar.

If the wave shows a gap later, select »Hook Setup …« in the menu. The app honors `CLAUDE_CONFIG_DIR`.

## How it works

Claude Code hooks send each event with `curl` to `http://127.0.0.1:47823/event`. If the app does not run, the hook
fails silently after at most 1 s.

| Hook | State |
|---|---|
| `SessionStart` | your turn, no notification. The last activity stays the time of the last prompt or answer. |
| `UserPromptSubmit`, `PostToolUse` | working |
| `PreToolUse` for `AskUserQuestion\|ExitPlanMode` | asks you |
| `Notification` | asks you, one notification for each question or plan |
| `Stop`, `StopFailure` | your turn |
| `SubagentStart`, `SubagentStop` | working, and the count of subagents in the row |
| `SessionEnd` | removed from the card, no notification |

Every 3 s, the app also reads these sources:

- **Transcripts:** the marker `[Request interrupted by user]` sets the session to »your turn«. Claude Code runs no
  hook for an interrupt.
- **`~/.claude/sessions`:** the app adds sessions that started before the app, and follows a newer status.
- **VS Code database:** the app reads `hiddenSessionIds` read-only, and removes archived sessions from the card.
- **Child processes:** a session with a running background shell command counts as working.

A session with a subagent that runs after the turn also counts as working. The menu bar counts each session once,
also with more subagents.

The app accepts only requests on the loopback interface with the header `X-Claude-Hook`. It refuses requests from
web pages.

## Files on your Mac

- `~/Library/Preferences/local.claude-code-notifier.app.plist` holds the settings that differ from the default.
- macOS keeps the notification permission, the login item and an empty Metal cache folder.
- The app writes no logs and no caches. Its only file is `morning-overview.md` in the project folder.

To remove the app, delete it. Then delete the settings file with `rm`. Do not use `defaults delete`, because it
leaves an empty file.

## Build

```bash
npm run start
```

This command builds the app with `build.sh` and restarts it. The build needs only the Xcode Command Line Tools. It
runs the unit tests first. If a test fails, the build stops. The build files stay in `build/` and `.build/`. To use an SDK
other than macOS 26, set `SDK=<path>`.

## Limits

- Every user account on the Mac can reach port 47823. Another account can send fake events or, while the app does
  not run, read your hook data. On a Mac with one user, this is not a problem.
- A click on a notification brings VS Code to the front, but not always the window of the session.
- Claude Code sends the permission `Notification` only after 6 s. If you answer faster, you get no notification.
- The project folder of the morning overview is always `~/S/plano`. Only Bitbucket gives PR data.
- `build.sh` signs each build ad hoc, so each build has a new code signature. A network filter such as Little Snitch
  can block a new build until you allow it again. Then the morning overview fails with a network error.
