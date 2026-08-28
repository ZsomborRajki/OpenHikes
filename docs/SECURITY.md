# Security Policy

## Supported versions

OpenHikes is a single-developer project with no release branches. Only the
current `main` is supported; fixes land there and nowhere else.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's [private vulnerability
reporting](https://github.com/ZsomborRajki/OpenHikes/security/advisories/new)
for the repository, or email <zsombor.rajki@gmail.com> if that is unavailable.

Please include what you found, how to reproduce it, and what an attacker gets
out of it. You should get an acknowledgement within a week. There is no bounty
programme.

## What is in scope

The app is local-first: there is no OpenHikes backend, no OpenHikes account and
no server-side attack surface. What is worth reporting is anything that lets
data leave the device other than as designed, or lets untrusted input take
control of it. In particular:

- Data reaching somewhere it should not — the mirrored CloudKit database, the
  `group.tappium.com.OpenHikes` App Group store the widget reads, the photo
  library, or a tile provider's servers.
- Anything exploitable through untrusted input: an imported GPX file, an
  `openhikes://` deep link, or a response from a tile or Overpass endpoint.
- A committed credential. `OpenHikes/Secrets.plist` is gitignored and holds the
  optional Stadia and Thunderforest keys; a key that reached a commit is worth
  reporting even if the commit is old.

## What is not in scope

- Anything requiring physical access to an unlocked, already-trusted device.
- Map data and tiles served by OpenStreetMap, Stadia Maps or Thunderforest —
  those are the providers' to secure. Report abuse to them.
- Vulnerabilities in Apple's frameworks. Report those to
  [Apple](https://security.apple.com/).

## What is already on

Secret scanning and push protection are enabled on this repository, so a
recognised credential is blocked at push time rather than found afterwards.
Dependency updates come from [Dependabot](../.github/dependabot.yml), and
[CodeQL](../.github/workflows/codeql.yml) analyses Swift on every push to `main`
and weekly.
