# Security Policy

## Supported versions

The latest released minor version receives fixes. This gem is pre-1.0; there
are no long-term support branches.

## Reporting a vulnerability

Report privately through GitHub's
[security advisory form](https://github.com/chayuto/discord_store/security/advisories/new)
rather than opening a public issue. Expect an acknowledgement within a week.

## What counts

In scope, and genuinely useful to hear about:

- Anything that lets an attacker read or forge stored records. The payload
  format is AES-256-GCM with the channel and key bound in as additional
  authenticated data; a way to get a record to authenticate under the wrong key,
  channel, or chunk ordinal is a real finding.
- Key material reaching a log, an exception message, or a Discord message.
- A path that reads or trusts a message this bot did not write. The
  `own_messages_only` guard is the boundary between a storage backend and a
  scraper, and a bypass is the most serious class of bug here.
- A CDN URL being persisted rather than re-resolved. Those URLs are signed and
  expiring, and treating one as durable is both a correctness and a disclosure
  problem.
- Anything that lets configuration reach the network before
  `i_understand_this_violates_discord_tos` has been set.

## What does not count

- **That the library violates Discord's Terms of Service.** It does, loudly and
  on purpose, and the README says so before it says anything else. That is a
  documented property, not a vulnerability.
- That data stored in Discord is visible to Discord. Encryption is on by
  default and the ciphertext still sits on someone else's computer, under an
  account they can close. Treat Discord as a hostile durable store; the threat
  model never assumed otherwise.
- Rate limiting, bans, or account termination resulting from use.
