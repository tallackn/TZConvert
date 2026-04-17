# TZ Convert Project

Quick macOS command-line timezone conversion using OpenAI structured parsing and TimeAPI.io.

```sh
./dist/tzconvert --set-openai-key
./dist/tzconvert "3pm this saturday for someone in london in my timezone"
./dist/tzconvert "from 3pm this saturday in london to local"
./dist/tzconvert "2026-04-17 09:30 from UTC to Europe/London"
```

Use `--explain` to see the OpenAI-parsed request without calling TimeAPI:

```sh
./dist/tzconvert --explain "3pm this saturday for someone in london in my timezone"
```

Use `--debug` to print the OpenAI request and response JSON for each model call:

```sh
./dist/tzconvert --debug "6pm in Istanbul next Tuesday in my timezone."
```

Or build and run through Xcode's command-line builder:

```sh
./script/build_and_run.sh --explain "3pm this saturday for someone in london in my timezone"
```

The OpenAI API key is stored in macOS Keychain by `--set-openai-key`. `OPENAI_API_KEY` can still be used to override the Keychain value for a single process.

`local`, `here`, and `my timezone` resolve to the Mac's current system time zone. The default parsing model is `gpt-5.4-nano`; set `OPENAI_MODEL` if you want to override it.
