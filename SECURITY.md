# Security Policy

Transcriber is a local-first alpha app that handles meeting audio, transcripts, optional
OpenAI API keys, and local debug artifacts. Please do not include private meeting content,
API keys, debug audio dumps, local SwiftData stores, or diagnostic logs in public issues.

## Supported Versions

Only the current `main` branch is supported for security review during alpha. When a
prerelease tag is published, the latest prerelease tag will be supported as well.

## Reporting

Use GitHub private vulnerability reporting:

```text
https://github.com/jremick/transcriber-app/security/advisories/new
```

Do not open public issues for suspected vulnerabilities, exposed secrets, meeting-content
leaks, authorization bypasses, or debug-artifact disclosure. If GitHub does not show the
private reporting form, open a minimal public issue that describes only the affected area
and asks for a private reporting path.
