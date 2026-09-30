#!/bin/sh
# install.sh - puts `lane` on your PATH (macOS, also Linux) and prints the line to paste into your agent.
# Run from the repo:  sh mac/install.sh [--no-path]
# No sudo needed. Re-running is safe.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")

PY=$(command -v python3 || true)
if [ -z "$PY" ]; then
    echo "Lanes Harness needs Python 3.9+. On macOS: xcode-select --install  (or: brew install python)" >&2
    exit 1
fi
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "Lanes Harness needs Python 3.9+; $PY is $("$PY" -V 2>&1)" >&2
    exit 1
fi
PY=$("$PY" -c 'import sys; print(sys.executable)')

LANES_HOME=${LANES_HOME:-$HOME/.lanes}
BIN="$LANES_HOME/bin"
mkdir -p "$BIN"
cat > "$BIN/lane" <<EOF
#!/bin/sh
exec "$PY" "$HERE/lane.py" "\$@"
EOF
chmod +x "$BIN/lane" "$HERE/lane.py" "$HERE/lanehost.py"
echo "shim  $BIN/lane"

if [ "$1" != "--no-path" ]; then
    case ":$PATH:" in
        *":$BIN:"*) echo "PATH  $BIN already on PATH" ;;
        *)
            case "$(basename "${SHELL:-sh}")" in
                zsh) RC="$HOME/.zshrc" ;;
                bash) if [ "$(uname)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
                *) RC="$HOME/.profile" ;;
            esac
            if ! grep -qs 'lanes/bin' "$RC"; then
                printf '\n# Lanes Harness\nexport PATH="%s:$PATH"\n' "$BIN" >> "$RC"
            fi
            echo "added $BIN to PATH in $RC (open a new terminal to pick it up)"
            ;;
    esac
fi

found=""
for c in claude codex grok cursor-agent; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$HOME/.local/bin/$c" ] || [ -x "$HOME/.grok/bin/$c" ]; then found="$found $c"; fi
done
echo "agents found:${found:- none yet (install at least one of claude, codex, grok, cursor-agent)}"

echo
echo "Paste this into your agent (Claude Code, Codex, Grok, Cursor) to make it a head:"
echo
echo "  You can run other coding agents as background workers. Read $REPO/HEAD.md and follow it: use the \`lane\` command to launch, watch and answer worker lanes."
echo
