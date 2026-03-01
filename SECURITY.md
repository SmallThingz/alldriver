# Security Policy

## Supported Versions

Security fixes are provided for the current `main` branch.

## Reporting a Vulnerability

If you discover a security issue:

1. Do not open a public issue with exploit details.
2. Open a private GitHub Security Advisory for the repository and include:
   - affected version/commit
   - reproduction steps
   - impact assessment
   - proposed mitigation (if available)

## Scope Notes

`alldriver` is an automation framework. Security reports are in scope when they involve:

- unintended command execution
- unsafe file/path handling
- credential/token leakage in logs/artifacts
- transport/session handling vulnerabilities

Out of scope:

- bypass/evasion requests or techniques
- anti-bot evasion strategies
