# Contributing

Start with the [README](README.md), [research note](docs/reverse-engineering.md) and [validation scope](docs/validation.md). Distinguish observations from hypotheses or unsupported API guarantees.

1. Create a topic branch and keep changes focused.
2. Use synthetic fixtures. Never commit real notes, account responses, tokens, active callback URLs, connection exports, databases or signing keys.
3. On macOS run `bash scripts/check-macos.sh`; for shared Swift or iOS changes also `bash scripts/check-ios.sh`; for Android `bash scripts/check-android.sh`. Windows helper changes should pass `python -m unittest discover -s Tests -v` with the pinned requirements.
4. Protocol code exists in Swift (`Sources/Shared`) and Kotlin (`android/…/local/samsungcloudnotes`). Change both together and keep the self-test vectors in step.
5. Explain the trigger, changed behavior, validation and remaining limits in your pull request.

Use a disposable note for authorized cloud write checks and retain its original data. CI must stay offline and must not use account secrets. Record upstream research/code sources and preserve license notices. Do not add Samsung binaries, decompiled code dumps, SDKs or raw captures.

Bug reports should include the visible app version, OS/architecture, action and sanitized error. HTTP status/error codes help; full URLs and response bodies may contain credentials. Use [Security](SECURITY.md) for sensitive findings.

Contributions must be compatible with MIT; preserve third-party notices and identify adaptations.
