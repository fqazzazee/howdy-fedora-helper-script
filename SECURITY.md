# Security policy — howdy-fedora-helper-script

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Do not open a public issue.

Use [private vulnerability reporting](https://github.com/fqazzazee/howdy-fedora-helper-script/security/advisories/new),
or email fadi.qazzazee@gmail.com with the details and, if you have one, a proof of
concept.

Expect an acknowledgment within 72 hours and an assessment within a week. If a fix is
warranted, you will get the timeline and credit in the release notes unless you would
rather not be named.

## Scope

**In scope:** the script in this repository and the configuration it writes. It changes
how you sign in to your system, so anything that weakens authentication, such as a
login that succeeds when it should not or a fallback that skips the password, is worth
reporting, along with command injection and unsafe file handling.

**Out of scope:** vulnerabilities in Howdy itself (report those upstream), the known
limits of face recognition as an authentication factor, and anything that requires an
attacker to already have the privileges the issue would grant.
