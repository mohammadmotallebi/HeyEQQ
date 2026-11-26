# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **don't** open a public issue for security problems. Report them privately through
[GitHub's private vulnerability reporting](../../security/advisories/new) instead.
Include steps to reproduce and the affected version. You'll get a reply as soon as possible.

## Scope

HeyEQQ processes audio locally and makes only one kind of network request: it fetches public
AutoEQ data from `raw.githubusercontent.com`. Relevant reports include problems in how it parses
imported EQ files or downloaded AutoEQ data, and anything that could make it capture or send audio
beyond what the README describes.
