# Gladais

Local voice assistant for conversation. It listens, answers, and speaks. It does not control apps or look at the screen.

## What stays on your machine

The repository does not include runtimes, model weights, voice recordings, or logs. Keep these local:

- `.venv/`, `.python/`, and `opt/` — Python and other downloaded tools
- `bin/ollama` — optional local Ollama binary or symlink
- `models/f5/*.safetensors` — F5-TTS weights (`models/f5/vocab.txt` is included)
- `voices/mine/reference.wav` and `voices/mine/reference.txt` — your voice sample and the exact words spoken in it
- `config.json` — system prompt, exit words, junk phrases, and the goodbye line
- `ollama.log`, `macos/server.log`, and pid files
- `Gladais.app` and Swift build output
- Whisper, Silero, and Ollama caches in your home directory

Set `GLADAIS_ROOT` if the Mac app cannot find this checkout next to `Gladais.app` or by walking up from the working directory.

## Mac app

From the repository root:

```bash
./macos/build.sh
open Gladais.app
```

The glass in the center is the button. Press it, or press Space, and speak. A pause ends the phrase. The transcript stays in the dialog, and dialogs are saved between launches under Application Support. The menu at the top chooses the Ollama model. Speech uses the voice sample in `voices/mine/`.

The first open loads Whisper and F5-TTS, so the glass sits in a warm idle state for a few seconds. macOS may ask for the microphone for Gladais.

## Run the terminal assistant

Use Python 3.12. Newer system Pythons may not have a PyTorch wheel.

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Install [Ollama](https://ollama.com), then pull a model that fits your memory. The default is `qwen2.5:14b`:

```bash
ollama pull qwen2.5:14b
./run.sh
```

macOS will ask for microphone access the first time. Allow it for Terminal (or whatever app you launched the script from): System Settings → Privacy & Security → Microphone.

Say an exit word from `config.json`, or press Ctrl+C to quit. After a silence with no speech, press Enter to listen again.

`./run.sh` uses `bin/ollama` when that file exists, and otherwise `ollama` on `PATH`.

## Speech settings

Copy the English template and edit it on this machine. The app reads `config.json` when that file exists, and otherwise `config.example.json`. Restart the app after a change.

```bash
cp config.example.json config.json
```

`system_prompt` is sent to the model. `exit_words` ends the terminal assistant when the utterance is one or two words and starts with one of them. `junk_phrases` drops transcripts that Whisper often invents from silence. A phrase ending in `*` also matches longer text that starts with it. `goodbye` is what the terminal assistant says before quitting.

## Voice sample

Place a short recording and its transcript next to each other:

```text
voices/mine/reference.wav
voices/mine/reference.txt
```

`reference.txt` must be the exact words in the recording. Do not commit either file.

F5-TTS weights go in `models/f5/model_last_inference.safetensors`. The matching vocabulary is `models/f5/vocab.txt`.

## What each piece does

- **Whisper** (`openai-whisper`, model `small`) turns microphone audio into text.
- **Ollama** writes the reply. The app talks to it at `http://127.0.0.1:11434`. The terminal assistant defaults to `qwen2.5:14b`.
- **F5-TTS** speaks replies in the Mac app from `voices/mine/`.
- **Silero TTS** (`v4_ru`, voice `xenia`) speaks replies in the terminal assistant. `torch.hub` loads the model code, and the weights are cached under the torch hub directory.
- **ffmpeg** needs to be on `PATH` because Whisper uses it when it opens audio files.
