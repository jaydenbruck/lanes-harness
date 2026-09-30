# Lanes Harness

Let one coding agent run other coding agents.

Lanes Harness gives any agent with a shell (Claude Code, Codex, Grok, Cursor) a `lane` command. With it,
the agent can start **Claude Code, Codex, Grok Build and Cursor Agent** sessions in the background, see
when each one finishes or asks a question, read what it wrote, answer it, restart it after a crash, and
shut it down. Each worker is the real CLI running in its own pseudoterminal, the same thing you would see
in a terminal, so nothing is emulated and every provider's own features keep working.

The agent driving the others is the **head**. The workers are **lanes**.

```
lane launch --name api --kind claude --cwd ~/src/myapp --prompt "Add a /health endpoint with a test."
lane launch --name sec --kind codex  --cwd ~/src/myapp --prompt "Review the auth module for security bugs."
lane wait --drain
[21:09:40] sec  NEEDS-INPUT(turn-complete)  Two findings written to SECURITY.md  (log 0..81233)
[21:12:02] api  NEEDS-INPUT(question)  Which framework? [1] FastAPI [2] Flask  (log 43313..47817)
lane send api --key enter
```

The head's context only grows by those one-line labels. Full transcripts stay on disk and are read on
demand (`lane read api --tail 40`).

## Install: paste one prompt into your agent

Open Claude Code, Codex, Cursor or Grok and paste:

```
Install Lanes Harness for me: clone https://github.com/jaydenbruck/lanes-harness and follow AGENT_SETUP.md in it.
```

The agent clones the repo, runs the installer for your OS, checks that a test lane works, reads the
manual, and offers to remember the tool in its global instructions. [AGENT_SETUP.md](AGENT_SETUP.md) is
what it follows.

In any later session, this line turns the agent into a head:

```
You can run other coding agents as background workers. Read <install folder>/HEAD.md and follow it: use the `lane` command to launch, watch and answer worker lanes.
```

[HEAD.md](HEAD.md) is written for the agent: the launch/wait/read/send loop, what every state means,
and how to answer each one.

## What it does

- **Launch** Claude Code, Codex, Grok Build, Cursor Agent, or any other command as a headless lane, with
  a model, an effort level, a working directory and a first prompt or brief file.
- **Know when to look.** Each lane's state (running, needs input, stalled, finished, died) is detected
  from the CLI's own hooks (Claude, Codex, Grok), process state, and prompt patterns on the settled
  screen. Every change becomes one labelled event in the head's queue.
- **Wait without polling.** `lane wait` blocks until something happens, then returns labels only.
- **Answer.** `lane send` types a message (atomic, bracketed paste), arrow keys, Esc, or a whole file.
- **Recover.** `lane restart` brings a dead lane back with its session resumed (Claude, Codex, Grok).
- **Watch.** `lane tab <name>` opens a terminal window on a lane, and `lane serve --open` shows every lane
  in a browser grid. You and the head can type into the same session at the same time.
- **Multiple heads.** Two head agents can run side by side. Each owns its lanes and can message the
  other's inbox.

Every byte a lane prints is kept in `console.log`, and every launch is recorded in `_registry.jsonl`.

## Platforms

| | Windows | macOS |
|---|---|---|
| status | tested: synthetic gauntlet plus real Claude, Codex and Cursor lanes | **not yet tested on a Mac.** The same code passes its test suite on Linux |
| needs | Windows 10 1809+ or 11, PowerShell 7 | Python 3.9+ (ships with the Xcode command line tools) |
| code | `Lanes.psm1`, `lane.ps1`, `src/LaneHost.cs` (compiled on install, no SDK) | `mac/` (Python, standard library only) |
| install | `pwsh -NoProfile -File install.ps1` | `sh mac/install.sh` |
| home | `%LOCALAPPDATA%\lanes` | `~/.lanes` |
| `lane tab` | Windows Terminal tab | Terminal.app window (`lane attach N` attaches in the current terminal) |

Both versions use the same commands, the same event format and the same browser viewer. On macOS,
lanes start hidden unless you pass `--visible`.

Either way you need at least one agent CLI, installed and logged in:
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`),
[Codex](https://github.com/openai/codex) (`codex`),
Grok Build (`grok`),
[Cursor Agent](https://cursor.com/cli) (`cursor-agent`).

### Manual install

```
git clone https://github.com/jaydenbruck/lanes-harness.git
cd lanes-harness
pwsh -NoProfile -File install.ps1     # Windows
sh mac/install.sh                     # macOS / Linux
```

The installer puts a `lane` shim on your PATH and prints the line to paste into your agent. Open a new
terminal afterwards.

## Commands

```
lane launch --name N --kind claude|codex|grok|cursor|other [--model M] [--effort LEVEL] [--cwd DIR]
            [--brief PATH] [--prompt TEXT] [--command CMD] [--visible|--hidden] [--is-head]
            [--stall-minutes 10] [--cols 160 --rows 45]
lane list [--all] [--head H] [--json]          lane status N
lane read N [--tail 40] [--from A --to B] [--raw] [--messages 3] [--events]
lane send N TEXT...  |  --key enter|esc|up|down|tab|ctrl-c|y|n  |  --raw "2"  |  --file PATH
lane kill N [--hard]     lane restart N [--prompt TEXT] [--fresh]
lane events [--drain] [--peek] [--max 200] [--json] [--as CONSUMER]
lane wait [--timeout 600] [--drain] [--as CONSUMER]
lane tab N     lane attach N (macOS)     lane serve [--port 7342] [--open]
lane head N     lane heads     lane whoami
```

On Windows the same verbs exist as PowerShell functions (`Import-Module .\Lanes.psm1`: `Start-Lane`,
`Get-Lane`, `Read-Lane`, `Send-Lane`, `Stop-Lane`, `Restart-Lane`, `Get-LaneEvent`, `Wait-LaneEvent`, ...).

## How each provider is launched

| kind | command | state detection | restart |
|---|---|---|---|
| `claude` | `claude --dangerously-skip-permissions --session-id <id> --settings <lane hooks>` | Claude hooks (Stop, AskUserQuestion, Notification, ...) | `--resume <id>` |
| `codex` | `codex --yolo -c notify=[lane hook] -c model_reasoning_effort=<effort>` | Codex `notify` (turn complete) | `codex resume <thread>` |
| `grok` | `grok --no-alt-screen --permission-mode bypassPermissions --session-id <id>` | Grok hooks (added to `~/.grok/config.toml` as a marked block, inert outside lanes) | `--resume <id>` |
| `cursor` | `cursor-agent --force --trust --workspace <cwd>` | screen patterns and process state | relaunch on the original prompt |
| `other` | whatever `--command` says | screen patterns and process state | relaunch |

Lanes run their agents with permission prompts skipped, because nobody is at the keyboard to approve
them. Only point lanes at work you would let that agent do unattended.

## Configuration

| variable | default | meaning |
|---|---|---|
| `LANES_HOME` | `%LOCALAPPDATA%\lanes` / `~/.lanes` | where lanes, head queues and the `lane` shim live |
| `LANES_ROOT` | `<LANES_HOME>/lanes` | lane folders and `_registry.jsonl` |
| `LANES_HEADS_ROOT` | `<LANES_HOME>/heads` | per-head event queues |
| `LANES_MAX_HEADS` | `2` | how many head agents may be registered at once |
| `LANES_STRICT_PRIVACY` | off | `1` refuses Grok lanes unless the account opted out of coding-data retention and local telemetry is off, and refuses Cursor models marked `NO ZDR` |

A lane that should not be auto-restarted can be listed (one name per line) in
`<LANES_HOME>/paused-lanes.txt`; `lane restart` then needs `--force`.

## How it works

Every lane is one small host process (`LaneHost.exe` on Windows, `mac/lanehost.py` on macOS) that owns a
pseudoterminal, spawns the CLI inside it, writes every byte to `<lane>/console.log`, keeps
`<lane>/state.json` current, and serves a named pipe (Windows) or Unix socket (macOS) so the head, terminal
windows and the browser viewer can all type into the same session. When the lane needs input, finishes,
stalls or dies, the host appends one labelled row to the owning head's `events.jsonl`. The `lane` command
holds no state: everything is on disk, so closing the terminal you launched lanes from does not kill them.

## Tests

```
pwsh -NoProfile -File tests\gauntlet.ps1 -SkipReal      # Windows, synthetic tests, no API usage
pwsh -NoProfile -File tests\gauntlet.ps1                # Windows, adds real Claude (haiku) and Grok lanes
python3 mac/tests/gauntlet.py                           # macOS / Linux, synthetic tests, no API usage
```

Both run against a throwaway `LANES_HOME` in the temp folder: an output flood with nothing lost, question
detection, ten lanes finishing in the same second, a killed host, lane-name reuse after a crash, restart,
stall detection, multi-head ownership, and more.

## License

MIT, © 2026 Jayden Bruck. The browser viewer bundles [xterm.js](https://xtermjs.org/) (MIT, see
`viewer/vendor/LICENSE-xterm.txt`).
