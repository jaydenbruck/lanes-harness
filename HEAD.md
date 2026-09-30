# Being a head agent

You are a normal coding-agent session (Claude Code, Codex, Grok, Cursor, anything with a shell). What makes
you a *head* is that you launch and drive *worker lanes*: real `claude`, `codex`, `grok` and `cursor-agent`
sessions, each running headless in its own pseudoconsole, through the `lane` command. You can keep going for
hours without the user pasting anything between agents.

`lane` is on PATH once Lanes Harness is installed (a thin shim over `lane.ps1` on Windows, `mac/lane.py` on macOS). Inside a lane it is always
on PATH, so lanes can run lanes too.

## The loop

```
lane launch --name api  --kind claude --model opus  --cwd C:\src\myapp --brief briefs\api.md
lane launch --name sec  --kind codex  --effort high --cwd C:\src\myapp --prompt "Audit the auth module."
lane launch --name fix  --kind grok               --cwd C:\src\myapp --prompt "Make the build green."
lane launch --name ui   --kind cursor             --cwd C:\src\myapp --prompt "Polish the settings page."
lane wait --drain --timeout 900          # blocks until something happens, then prints labels only
```

`lane wait` and `lane events --drain` return one line per event and nothing else:

```
[21:08:12] api  NEEDS-INPUT(question)  Which plan? [1] Plan A [2] Plan B  (log 43313..47817)
[21:09:40] sec  NEEDS-INPUT(turn-complete)  Audit done: two findings written to SECURITY.md  (log 0..81233)
[21:31:02] api  DIED(exit--1)  API Error: 529 overloaded  (log 47833..53891)
```

That is the whole design: your context grows by labels, never by other agents' transcripts. Read deeper
only when you decide to:

```
lane read api --tail 40                  # the last 40 screen lines, escape codes stripped
lane read api --from 43313 --to 47817    # the exact byte range an event pointed at
lane read api --messages 2               # claude/grok: the last two assistant messages from its transcript
lane read api --raw --bytes 20000        # raw bytes if you really want them
```

Answer a lane the way the user would have:

```
lane send api "Plan B. Then continue with the build."      # one message + Enter, atomic, bracketed
lane send api --key down,enter                             # pick the second option in a dialog
lane send api --key esc                                    # cancel a dialog
lane send api --raw "y"                                    # bare keystrokes, no Enter
lane send api --file C:\src\myapp\notes\decision.md        # deliver a file verbatim
```

When a lane dies (API 529, a crash, the box rebooted): `lane restart api`. Claude and Grok lanes come back
with `--resume <their session>`, Codex lanes with `codex resume <thread>`. Cursor mints its own chat id and
the harness does not capture it yet, so a Cursor lane restarts on its original prompt. Either way the
transcript on disk continues in the same `console.log`. Codex launches default to
`high` effort, record it in `launch.json`, and restarts preserve it. Launch and restart read the actual
effort back from the Codex status bar and report `OK`, `DRIFT`, or `CANNOT-SEE`. `lane kill api` ends one
cleanly (`--hard` if it will not leave).

## What the states mean

| state | mechanism | what you do |
|---|---|---|
| `RUNNING` | process alive, output flowing, no hook says otherwise | nothing |
| `NEEDS-INPUT(turn-complete)` | Claude/Grok `Stop` hook, Codex `agent-turn-complete`: the turn is over, the CLI sits at its prompt; label = its last message | read the label; send the next instruction, or kill it if the brief is done |
| `NEEDS-INPUT(question)` | Claude `AskUserQuestion` (PreToolUse hook); label = the question and the options | `lane send N --key down,enter` / `--key enter` / type an answer |
| `NEEDS-INPUT(permission)` / `(prompt)` | permission dialog, trust dialog, or a generic `(y/n)` pattern after 4 s of quiet | `lane read N --tail 12` if the label is not enough, then answer |
| `NEEDS-INPUT(idle)` | Claude's own 60 s idle notification | same as turn-complete |
| `STALLED(no-output-10m)` | alive, nothing printed for 10 min (per-launch `--stall-minutes`) | `lane read N --tail 20`; `lane send N "status?"`; restart if it is hung |
| `FINISHED(exit-0)` | the process exited 0 | file the result |
| `DIED(exit-N)` / `DIED(host-lost)` | non-zero exit, an error on screen at exit, or the host process vanished | `lane restart N` |

Detection is mechanical: hooks the CLIs fire themselves, plus process state, plus a prompt pattern on
the settled screen. Nothing guesses from vibes.

## Ownership, and who is draining

A lane belongs to the head that launched it (`$env:LANES_HEAD`, set inside your session by the harness).
You cannot type into another head's lanes. You can type into the other head's *inbox*, which is its own
terminal: `lane send <other-head-lane> "..."`. `lane list` shows every lane with its owner.

The queue is per head; the **cursor is per consumer**. Your consumer id is your head name if you are a
registered head, else your lane name if you run inside a lane, else `user` (the human at their own
terminal); `lane whoami` prints it, `--as <name>` overrides it. Two sessions that share a head identity
therefore each see every event once, and neither can mark the other's unseen rows as seen. If you are a
helper session that was not launched with `--is-head`, drain with `--as <your-name>` or rely on the
default: your lane name.

## Where things are

`LANES_HOME` defaults to `%LOCALAPPDATA%\lanes` on Windows and `~/.lanes` on macOS.

- `<LANES_HOME>\lanes\<name>\console.log` — the full transcript, every byte, as it happened
- `<LANES_HOME>\lanes\<name>\state.json` — pid, model, cwd, started, lastOutputAt, state, why, label, sessionId, bytes
- `<LANES_HOME>\lanes\_registry.jsonl` — every launch ever: command, model, cwd, brief, who launched it
- `<LANES_HOME>\heads\<head>\events.jsonl` — your queue; `events.cursor` is how far you have drained
- `lane serve --open` — the grid view in a browser (`http://127.0.0.1:7342/`): every lane, state-coloured, click to focus and type
- `lane tab <name>` — a terminal on a lane (a Windows Terminal tab, or a Terminal.app window on macOS); the user can watch and type there, and you both drive the same PTY. On macOS, `lane attach <name>` attaches in the current terminal

## Rules that hold for you as a head

Do not invent decisions the user never made. A lane that needs a decision only the user can give gets
one line from you to them in your terminal, not a stalled lane and silence. Log what you decided on the
user's behalf in your report. You are the one conversation the user has; the lanes are yours to run.
