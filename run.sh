#!/usr/bin/env bash
# Start the Gladais voice assistant.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export PATH="$ROOT/bin:/opt/homebrew/bin:$PATH"

if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  echo "Missing $ROOT/.venv. Python 3.12 environment is not installed." >&2
  exit 1
fi

OLLAMA_BIN=""
if [[ -x "$ROOT/bin/ollama" ]]; then
  OLLAMA_BIN="$ROOT/bin/ollama"
elif command -v ollama >/dev/null 2>&1; then
  OLLAMA_BIN="$(command -v ollama)"
else
  echo "Ollama is not installed." >&2
  exit 1
fi

if ! curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null; then
  echo "Starting Ollama..."
  nohup "$OLLAMA_BIN" serve >>"$ROOT/ollama.log" 2>&1 &
  echo $! >"$ROOT/ollama.pid"
  ready=0
  for _ in $(seq 1 40); do
    if curl -sf --max-time 1 http://127.0.0.1:11434/api/tags >/dev/null; then
      ready=1
      break
    fi
    sleep 0.5
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "Ollama did not start. See $ROOT/ollama.log" >&2
    exit 1
  fi
fi

if ! curl -sf --max-time 5 http://127.0.0.1:11434/api/tags | grep -q '"name":"qwen2.5:14b'; then
  echo "Model qwen2.5:14b is not installed. Run: $OLLAMA_BIN pull qwen2.5:14b" >&2
  exit 1
fi

exec "$ROOT/.venv/bin/python" "$ROOT/main.py"
