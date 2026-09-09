# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-09

### Added

- **`DiscordStore::Search`** — `client.search`, a wrapper over
  `GET /guilds/{id}/messages/search`. Discord does have a query API; this
  exposes it deliberately and uses it for almost nothing, because it is
  documented to under-return, is eventually consistent, caps a query at ten
  thousand rows, and cannot see through AES-256-GCM anyway. SQLite remains the
  query layer. Results come back as a `Result` rather than an Array, because an
  Array invites the `.size` that Discord says not to trust.
- **`BlobStore#orphans`** — chunks that no live manifest points at, the residue
  of an interrupted write or a half-finished delete. Invisible to every other
  method, because every other method starts from a manifest. This is the query
  that justified the interface.
- **`rake discord:orphans`**, and a search line in `rake discord:doctor` that
  distinguishes "no intent" from "broken".
- **`search_retry_floor`** configuration, so an unindexed guild answering
  `retry_after: 0` does not become a hot loop.

### Fixed

- A comment in `blob_store.rb` claimed "Discord gives bots no search". It does;
  the endpoint is documented and requires the `MESSAGE_CONTENT` privileged
  intent. The README carried a softer version of the same error.

### Security

- Every search pins `author_id` to this application before the request leaves,
  and filters the response again on the way in. Searching for another author
  raises `SearchScopeError` while `own_messages_only` is on. Search reads across
  a guild rather than a channel it was handed, which makes it the one endpoint
  here that could turn a storage backend into a scraper.

## [0.1.0] - 2026-09-09

First release.

### Added

- **Transport** — a rate-limit-aware Discord REST client that learns bucket
  topology from response headers, honours `X-RateLimit-Scope` on 429s, retries
  with full jitter, and caches connections per fiber rather than per thread.
- **Quota** — a token-bucket semaphore over the bot's global request budget,
  replacing the connection pool. The scarce resource over an HTTP API is
  permission to ask, not sockets.
- **Log** — an encrypted append-only log across one or more channels. Records
  are packed many per message, spilled to attachments when oversized, and
  deduplicated on retry via the Discord message `nonce`. Channels are
  partitions: total order within one, none across them.
- **Cipher** — AES-256-GCM with additional authenticated data binding each
  payload to its channel, and a separate binary envelope for attachments that
  avoids the 33% base64 penalty.
- **Snowflake** — treats Discord message IDs as the k-sortable, time-encoded
  primary keys they are, including synthetic bounds for time-range pagination.
- **BlobStore** — chunked object storage that never persists a CDN URL and
  re-resolves on every read, so it survives Discord's expiring signed links.
  Range reads fetch only the chunks they touch.
- **`ActiveStorage::Service::DiscordService`** — with proxy mode as the
  documented configuration. Passes Rails' own `SharedServiceTests` conformance
  suite in full, including `compose` and 5 MB streaming slices.
- **`ActiveRecord::ConnectionAdapters::DiscordAdapter`** — a SQLite adapter that
  mirrors every write into a Discord channel and can rebuild the database from
  it. Journal modes `:sync`, `:async` and `:off`. Savepoints are refused while
  journalling, because a sent message cannot be un-sent.
- **Replay** — idempotent, resumable reconstruction of a local database from the
  log, with cursor tracking.
- **KV** — Kredis-shaped values. Scalars are last-write-wins documents; counters
  and lists are append-only, so concurrent writers do not lose each other's work.
- **`Transport::Fake`** — an in-memory Discord that models monotonic snowflakes,
  nonce deduplication, the 14-day bulk-delete window, rate limiting, foreign
  authors, and CDN links that genuinely expire.
- **Rake tasks** — `discord:replay`, `discord:status`, `discord:compact`,
  `discord:doctor`, `discord:probe`, `discord:key`.
- **Safety** — the library refuses to make a request without an explicit
  Terms of Service acknowledgement, and reads only messages its own bot wrote.

### Verified against

- Ruby 3.1, 3.2, 3.3 and 3.4.
- Rails 7.2, 8.0 and 8.1, via Appraisal. The floor is 7.2 because
  `ActiveRecord::ConnectionAdapters.register` does not exist before it.
- Rails' vendored ActiveStorage conformance suite, 14 cases, nothing skipped.

Not verified against live Discord. The attachment ceiling, CDN `Range` support
and real throughput are discovered at runtime rather than hardcoded, and none of
them have been measured against a real guild.

[0.2.0]: https://github.com/chayuto/discord_store/releases/tag/v0.2.0
[0.1.0]: https://github.com/chayuto/discord_store/releases/tag/v0.1.0
