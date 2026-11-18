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
  Archived sessions are not in the card. A click on a row opens the chat of the session in VS Code.
  Between the texts, each row has a wave like the menu bar: green while the session works, purple for a running
  report, and still in a muted menu bar color for the other sessions.
- **Notifications:** one for each session. A newer one replaces the older one. A click opens the chat of the session in VS Code, like a
  click on its row.
- **Sound:** the ring of the bubble. It stops after 5 minutes without an answer. A new morning overview plays »Funk«
  once. No sound plays while a macOS Focus is on. »Play Sounds« in the menu turns all sounds off.

## Morning overview

Each run writes a new file with the date as its name, for example `2026-11-05.md`. The file goes into the folder that
you enter in »Setup …« › »Schedules« › »Folder«. Without a folder, the run fails and tells you where to enter it. The
project folder is `~/S/plano`. The file is a short list of open tasks in
six sections: the open PRs of others, my open PRs, draft PRs, the tickets of the sprint, open branches and other
work. »Open branches« lists only the local branches that no listed PR or ticket covers. In each section, the easiest
tasks come first. Each task has a title line with the links of the PR and the ticket and a short title. Below it,
each next action is a sub-item with a checkbox. A sub-item without a checkbox is no task and gets no ID. If the folder is the root of a git repository, the app adds the dated files to `.git/info/exclude`, so git never stages them.

- **When:** the first start, wake or unlock on a weekday from 6:00 on, or a check every 15 minutes. A file updated
  today from 6:00 on skips the run. »Update Now« in the menu starts a run at any time. »Every Weekday at 6:00« turns
  the daily run off.
- **Done:** a notification says how many tasks are open. A click on it opens the file in Obsidian, or in VS Code without Obsidian. Until you open
  the file, the menu shows a purple dot behind »Open Morning Overview«, and the menu bar shows one left of the wave. A failure always gets a notification, and the menu shows its reason.
- **Unchanged tasks:** Claude writes `KEEP <ID>` for an old task that stays the same, and the app copies the old task
  with its open sub-items. In the PR sections, a task stays the same only for a PR with no change since the last run:
  no commit, also no local one, and no comment, task, build, merge conflict, review, review report or turn. For this,
  the app saves the state of each open PR. If a `.md` name in a PR task is no plan or project file, it does not count.
  An example is a file on the branch of the PR. A task whose sub-items are all ticked goes away. While a run is
  active, the app does not give new IDs in the old file. So each ID names the same task for the app and for Claude.
  Claude does not read an unchanged plan or review report again. Unchanged means: no change to the file, and no new
  commits on its PR or branch since the old file. A merged PR, a commit on `origin` and a moved file count as a change. A changed 🚫 or a ticket
  that is done now also makes Claude write the task again. For this, the app saves the newest commit of each open PR
  after each run that wrote a file.
- **Unchanged tasks without files:** in »Open Branches« and »Optional Work«, a task without a plan or report can stay
  the same too. It must name a branch, a worktree, an open PR or a session, and none of them changed. For this, the
  app saves the state of each branch, worktree, session and ticket. These count as a change: a new commit or
  uncommitted change, a new session message, a new Jira status, and a new PR of the branch. A ticket in the sprint and
  an archived session count too.
- **New review:** a review report is a file `reviews/<PR>-<name>.md` in the project folder that names its »reviewed
  commit« or »reviewed at« commit. If no report of the PR names its newest commit, the app adds »Run `/nn-review #<PR>`
  again« to the PR, without Claude. It is the first next action, or the one after the merge of a merge conflict. Your
  own PR gets it only when one of the commits after the reviewed commit is from you. The app reads the authors of the
  commits from Bitbucket.
- **Links:** Claude writes short refs, for example `[#1234]`, `[PROJ-123]` and `[plan.md]`, and the app makes the
  links. So Claude writes less text, and no link has a wrong URL. A ticket ref needs a project key of Jira, so that
  for example `[UTF-8]` stays text.
- **File texts:** the JSON has the text of each plan and report that Claude must read, at most 50 KB for each file and
  150 KB in total. The JSON also has the old overview and the index of the Claude memory of the project. So Claude
  needs fewer reads, and each read is one turn less.
- **Outdated files:** the app finds the plans and reports that »Cleanup Work« needs. An outdated file has no open PR
  that names it, and one of these facts is true: its review PR is closed, a ticket is done, a branch is merged or gone,
  or all its steps are done. If the PR of a report was declined, the app writes »Delete <file>« itself, because the code
  never reached `dev`. Claude checks the findings of the other outdated files, at most 5 files in one run. A file with an
  open task in »Cleanup Work« needs no check. A file with an open task in »Optional Work« needs no check either.
  The exceptions are a changed file, and a file that was not outdated at the last run. A checked file that no task
  names, for example a plan of another project, needs no new check until it changes. For this, the app saves the outdated files after each run
  that wrote a file.
- **Stats:** after each run, also after a failure or a stop, the app writes `stats.md` in the same folder. It shows the
  time of each step of the last run, for example the Bitbucket requests and the Claude run, and its share of the total.
  »Stats« next to »Open« in the menu opens the file.
- **Sources:**
  - The newest dated file in the folder. Done tasks leave it.
  - The open PRs on Bitbucket, with their newest comments. The repo comes from the remote `origin`. Claude does not
    get the tasks of a PR, and not the comments of a task with their replies. You see them in the PR, so no next action repeats
    them. The title line of the PR is the reminder.
  - The PRs of other devs that were merged since the last overview, that change `scheduler.frontend.ng2/`, and that
    I did not approve or send back. The app writes them into »Other Devs' Merges« near the end, without Claude. An
    open task stays in the next overview. A ticked task leaves it.
  - The Jira tickets of the open sprint, with their states and »blocks« links. »Cleanup Work« also lists your tickets
    that are »In Progress« or »Untested« and in no sprint.
  - Untracked plan files, uncommitted and unpushed work in every worktree, the plans in `~/.claude/plans`, the Claude
    memory of the project and the titles of recent sessions.

The prompt is `Resources/morning-overview-prompt.md`. The app fetches the PRs and the Jira tickets itself. For this,
the login shell must set these variables:

- `BITBUCKET_API_EMAIL` and `BITBUCKET_API_TOKEN`. The app sends only GET requests to Bitbucket.
- `JIRA_API_TOKEN`: an Atlassian API token with scopes for the app Jira. Create it on
  id.atlassian.com/manage-profile/security/api-tokens with »Create API token with scopes«, and give it only the scope
  `read:jira-work`. The token expires after at most 365 days. Before that date, make a new one. The app uses the email
  in `JIRA_API_EMAIL`, else the one in `BITBUCKET_API_EMAIL`.
- `JIRA_SITE`, for example `drplano.atlassian.net`. Without it, the app takes the site of a ticket link that Claude
  wrote in the old overview. A new, empty folder has no such link.

The app reads the Jira tickets with GET requests, and with POST requests to `issue/bulkfetch` that only read. If Jira
fails, the run continues, and the overview says »Jira not available« and the reason. If a network error stops Jira and the
Bitbucket requests work, the app tries the Jira requests once more. The app gets the state of each ticket in a PR
title, a branch name, a plan or a session title. It also gets the state of each ticket in the name of an untracked
file or in the old overview. Then the app runs
`claude -p` through the login shell, and Claude only reads:

- `--tools Read,Grep,Glob,Bash` leaves out every tool that writes.
- `--restricted` ignores the settings files, so their allow rules do not apply.
- `--permission-mode dontAsk` refuses every call that is not on the allow list, without a prompt. Only reads of the
  project folders are on it. Bash runs only the commands that Claude Code knows as read-only, for example `git status`.
- `--strict-mcp-config` starts no MCP server, also not the servers in the `.mcp.json` of the project.

Claude prints the overview, and the app writes the file. The run never gets `BITBUCKET_API_TOKEN`, `JIRA_API_TOKEN` or
`SLACK_USER_TOKEN`.
If a Bitbucket request fails, the run fails without writing an overview. This includes the request for the details of
one PR. So missing PR data cannot look like a successful update.

## Usage of your accounts

Below the sessions, a second card shows the limits of each Claude account. Each account has one line with its name
and the reset time, and below it one bar. The upper two thirds of the bar show the weekly limit, the lower third the
Fable limit. From 80 % on, a part is red. Hover over the bar to see both percentages. Hover over the name to see the full
email.
A »VS Code« tag marks the account that the VS Code sessions use. That account comes first. The other accounts follow by
their reset time, the soonest first.

- **Accounts:** the default folder `~/.claude`, and each folder `~/.claude-*` with a `.claude.json` in it.
- **Add an account:** click »Accounts …« in the card, then »Add Account …«. The app creates the folder
  `~/.claude-account-<n>` and runs `claude auth login` for it, which opens the login page of Claude. The page decides
  the account. If the account is in the list already, the app logs
  out of the new folder and deletes it. An account without a login gets »Log In«.
- **Remove an account:** the minus button in the Accounts tab. For a folder that the app created, the app logs out and
  deletes the folder. Any other folder, for example `~/.claude`, only leaves the list.
- **How:** the app runs `claude -p` with a prompt of one token for each account, and reads the limits from its
  output. The run uses Fable, because only a Fable request gets the Fable limit. Without Fable, it uses Haiku. The
  app never reads a login token. The run skips all hooks, so it does not show as a session.
- **When:** the app updates the data once at its start. A click on the arrow in the card updates it too. If you open
  the menu and the data is older than 10 minutes, the app updates it.
- **Cost:** each update uses less than 1000 tokens of Fable, so a little of the Fable limit.
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
4. Put `export SLACK_USER_TOKEN=xoxp-…` into the file with the `BITBUCKET_API_*` variables, for example `~/.zprofile`
   or `~/.zshenv`. The app reads the login shell, which does not read `~/.zshrc`.

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
   The extension also tells the app which VS Code windows are open. A click on a row in the card then opens the chat
   in the window of the session. Without the extension, VS Code opens the folder of the session, and it can open a
   new window for it.

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
- The app writes no logs and no caches. Its only files are the morning overviews and `stats.md` in the folder of the setting, and DiDi in the project folder.
- `~/Library/Application Support/local.claude-code-notifier.app/morning-overview/` holds the last overview that the app
  wrote. It also holds these files of the last run. `pull-request-heads.json` has the newest commit of each open PR,
  and `pull-request-states.json` has the state of each open PR. `outdated-files.json` has the outdated plans and
  reports, and the names of all plans and reports. `named-states.json` has the state of each branch, worktree, session
  and ticket. `last-run.json` and `last-run-input.json` hold the
  command and the input of the Claude run, without tokens. The same files of DiDi are in the folder `didi`.
- `python3 scripts/replay-last-run.py default medium low` runs the last Claude run again with each effort level, at
  the same time. It writes each answer and a table with the time into the folder `replay`, and never the overview.
  Each replay uses the usage of your Claude plan.

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
