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

The app is local-first and there is no OpenHikes account, but that is not the
same as having nothing on a server. Sharing a hike publishes it to a **public
CloudKit database this project owns and every user can read**, and its security
is entirely a hand-maintained configuration of permissions and indexes. That is
the most interesting thing here to report on, so it is named first.

### The public community database

The rules are spelled out in `OpenHikes/Community/CommunitySchema.swift`, and
anything the deployed environment does that contradicts that file is worth
reporting:

- **`CommunityHikeSubmission`** — what a hiker uploads. `_world` read,
  `_icloud` create, `_creator` **read only**. If write came back to `_creator`,
  an author could swap the route or the photographs of an already-approved
  submission and have the app serve the replacement under the approved listing,
  unreviewed. That is the whole reason there are two record types.
- **`CommunityHikeSubmission` carries no index at all**, `___recordID`
  included. Any way to *enumerate* that type is a finding: the absence of an
  index is the only thing keeping world-readable pending submissions from being
  listed, and it has gone wrong once already — a field reached the development
  environment carrying `QUERYABLE SEARCHABLE SORTABLE` by itself, because a
  schema promote can drop an index and downgrade a grant, not only add.
- **`CommunityHike`** — the published listing. `_world` read; create and write
  granted to a custom admin role — the reviewer's — and to nobody else. The app
  *does* have a method for it (`CommunityTransporting.publish(_:)`), and that
  is not the control: the grant is. A build calling it from an account outside
  the role gets a permission failure, exactly as a hand-rolled request would.
  A report that the method exists is not a finding; a report that a
  non-reviewer's call **succeeded** is.
- **`CommunitySubmissionNotice`** — the reviewer's queue. `_icloud` create,
  and read and write granted to the `reviewer` role and to nobody else. It
  carries a reference to a submission and no other field. This is the one type
  in the schema that is indexed on purpose, and its read grant is what makes
  that safe — a query returns the rows the caller may read, which for
  everybody but the reviewer is none. **Any read of this type by an account
  outside the role is a finding**, because a notice names a pending
  submission and a name is all it takes to fetch one.
- **`CommunityHikeSubmission` grants `WRITE` to `reviewer`**, which is how a
  declined submission is deleted. Write reaching any other role — `_creator`
  above all — is the finding described in the first bullet.
- **`CommunityHike.authorID`** is deliberately unindexed as well: blocking is
  applied on the device, so the field is never a predicate, and indexing it
  would let anybody enumerate one person's published hikes.

**Known and accepted, so a report of it is not new:** an unreviewed submission
is readable by anyone holding its record name — unguessable, and not
enumerable, but a name rather than a permission. What would be new is a way to
*obtain* such a name without being given it.

### On the device

- Data reaching somewhere it should not — the mirrored (private) CloudKit
  database, the `group.tappium.com.OpenHikes` App Group store the widget reads,
  the photo library, or a tile provider's servers.
- Anything exploitable through untrusted input: an imported GPX file, an
  `openhikes://` deep link, a response from a tile or Overpass endpoint, or the
  contents of a community record — which is text and assets another user
  uploaded.
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
