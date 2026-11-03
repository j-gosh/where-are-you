# Security

Where Are You handles people's locations, so security reports are taken seriously.

## Reporting a vulnerability

**Don't open a public issue.** Instead, use GitHub's private reporting: go to the repository's **Security** tab and choose **Report a vulnerability**. Please include steps to reproduce the problem, and say what an attacker could learn or do.

## What's in scope

- Anything that lets someone read locations, names or alert details they shouldn't (see "How the encryption works" in the README).
- Ways around the Firestore security rules or the Cloud Functions' checks.
- Weaknesses in how keys are generated, stored, pinned or verified.

Limitations the README already describes (no forward secrecy, metadata visible to the server, and so on) are known. Ideas for addressing them are still welcome, as regular issues.
