# Setting up Lanes Harness

These steps are for a coding agent (Claude Code, Codex, Cursor, Grok, ...) that a user asked to install
Lanes Harness. Do every step yourself. Stop to ask the user only where a step says so.

Lanes Harness gives you a `lane` command for running other coding agents (Claude Code, Codex, Grok
Build, Cursor Agent) as headless background sessions: launch them, wait for them to finish or ask
something, read what they wrote, answer, restart, stop.

## 1. Get the code

Install to `~/lanes-harness` (Windows: `%USERPROFILE%\lanes-harness`) unless the user named another folder.
If that folder already holds a clone of this repository, run `git pull` in it instead.

```
git clone https://github.com/jaydenbruck/lanes-harness.git ~/lanes-harness
```

## 2. Install

**Windows** (10 1809+ or 11)
- Needs PowerShell 7: `pwsh -v`. If it is missing, ask the user, then `winget install -e --id Microsoft.PowerShell`.
- Run `pwsh -NoProfile -File <folder>\install.ps1`. It compiles `bin\LaneHost.exe` with the C# compiler that
  ships with Windows (no SDK, no admin), writes a `lane` shim to `%LOCALAPPDATA%\lanes\bin` and adds that
  folder to the user PATH.
- Your shell does not see the new PATH yet. For the rest of this setup call `%LOCALAPPDATA%\lanes\bin\lane.cmd`.

**macOS** (also Linux). The Mac version has not been tested on a real Mac yet (it passes its test suite on
Linux); tell the user so.
- Needs Python 3.9+: `python3 --version`. If it is missing on macOS, ask the user, then `xcode-select --install`.
- Run `sh <folder>/mac/install.sh`. It writes a `lane` shim to `~/.lanes/bin` and adds that folder to PATH in
  the user's shell profile.
- Your shell does not see the new PATH yet. For the rest of this setup call `~/.lanes/bin/lane`.

The installer prints which agent CLIs it found (`claude`, `codex`, `grok`, `cursor-agent`). Lanes can only
run agents that are installed and logged in.

## 3. Check it works

Launch a shell as a lane, wait until it sits at its prompt, type into it, read the result, stop it:

```
Windows:  lane launch --name hello --kind other --hidden --command "pwsh -NoLogo -NoProfile"
macOS:    lane launch --name hello --kind other --command "env PS1='$ ' sh -i"

lane wait --drain --timeout 30                  # expect: hello  NEEDS-INPUT(prompt)  followed by the shell prompt
lane send hello "echo answer=42"
lane read hello --tail 3                        # expect a line: answer=42
lane kill hello                                 # the lane ends; `lane wait --drain` shows its last event
```

If an agent CLI was found, also run one real lane, for example
`lane launch --name smoke --kind claude --model haiku --cwd <some folder> --prompt "Reply with the word OK."`,
then `lane wait --drain --timeout 120`. A new folder can first show the CLI's "trust this folder?" dialog
as `NEEDS-INPUT(prompt)`: read it with `lane read smoke --tail 12` and pick the trust option with `lane send
smoke --key enter` (or `--key down,enter` if "No" is highlighted). Then `lane kill smoke`.

## 4. Learn the loop

Read `<folder>/HEAD.md` completely. It is the manual for driving lanes: launch, wait, read, answer, what each
state means. From now on in this session you can use it.

## 5. Make it stick (ask the user first)

Future sessions will not know about `lane` unless it is written down. Offer to add this line to the user's
global agent instructions, and only edit them if they agree:

> Lanes Harness is installed. To run other coding agents as background workers, read `<folder>/HEAD.md` and use the `lane` command.

- Claude Code: `~/.claude/CLAUDE.md`
- Codex: `~/.codex/AGENTS.md`
- Cursor: Settings > Rules > User Rules
- Other agents: wherever they keep user-level instructions

## 6. Report

Tell the user where it is installed, which agents it found, the result of step 3, and this line for any
session that should use lanes:

> You can run other coding agents as background workers. Read `<folder>/HEAD.md` and follow it: use the `lane` command to launch, watch and answer worker lanes.
