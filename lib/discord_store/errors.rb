# frozen_string_literal: true

module DiscordStore
  # Base class for every error this library raises.
  class Error < StandardError; end

  # Raised when the library is used before it has been configured, or when a
  # configuration value is missing or nonsensical.
  class ConfigurationError < Error; end

  # Raised when the caller has not acknowledged that this library operates in
  # violation of the Discord Developer Terms of Service. See
  # {DiscordStore::Configuration#i_understand_this_violates_discord_tos}.
  class UnacknowledgedError < Error
    DEFAULT_MESSAGE = <<~MSG
      discord_store stores application data in Discord messages and attachments.
      That is an explicit violation of the Discord Developer Terms of Service and
      the Discord API Developer Policy, and it can get your bot token revoked and
      your account actioned without warning.

      This library will not talk to Discord until you say, in code, that you know
      that:

          DiscordStore.configure do |c|
            c.i_understand_this_violates_discord_tos = true
          end

      Do not set this in an application you did not build for yourself.
    MSG

    def initialize(msg = DEFAULT_MESSAGE)
      super
    end
  end

  # Base class for anything that came back from Discord's REST API.
  class APIError < Error
    attr_reader :status, :code, :response_body

    def initialize(message, status: nil, code: nil, response_body: nil)
      @status = status
      @code = code
      @response_body = response_body
      super(message)
    end
  end

  # 401/403 — the token is wrong, expired, or lacks the required permission.
  class AuthError < APIError; end

  # 404 — the channel, message, or attachment is gone. In a store built on a
  # chat app this is a routine occurrence, not an exceptional one: a human with
  # Manage Messages can delete your data at any time from the client UI.
  class NotFoundError < APIError; end

  # 429 — rate limited. Carries the server-supplied backoff so callers can obey
  # it rather than guessing.
  class RateLimitedError < APIError
    attr_reader :retry_after, :scope, :global

    def initialize(message, retry_after:, scope: nil, global: false, **kwargs)
      @retry_after = retry_after
      @scope = scope
      @global = global
      super(message, **kwargs)
    end
  end

  # A request exhausted its retry budget.
  class ExhaustedError < Error; end

  # The local process could not acquire rate-limit quota within the configured
  # timeout. This is the moral equivalent of ActiveRecord::ConnectionTimeoutError,
  # but the exhausted resource is request budget, not sockets.
  class QuotaTimeoutError < Error; end

  # A stored payload could not be decrypted or did not authenticate.
  class DecryptionError < Error; end

  # A stored payload is structurally wrong — truncated, wrong version, or not
  # something this library wrote.
  class CorruptRecordError < Error; end

  # A record was larger than anything this library can represent, even after
  # spilling to an attachment.
  class PayloadTooLargeError < Error; end

  # Raised when a message that was expected to be one of ours turns out to have
  # been written by somebody else. discord_store only ever reads its own bot's
  # messages; see DiscordStore::Transport::REST#assert_own_message!
  class ForeignMessageError < Error; end

  # Discord's message index had not caught up with the messages being searched
  # for, and did not catch up within the allowed number of retries.
  #
  # This is not a failure so much as a statement about what search is: an index
  # maintained asynchronously beside the messages, not the messages themselves.
  # A write is durable the moment create_message returns; it is *findable* some
  # time after that, and Discord does not promise when.
  class IndexNotReadyError < Error
    attr_reader :documents_indexed

    def initialize(message = nil, documents_indexed: nil)
      @documents_indexed = documents_indexed
      super(message || "Discord's search index is not ready for this guild yet")
    end
  end

  # Searching requires the MESSAGE_CONTENT privileged intent, which Discord
  # grants per application and reviews by hand once a bot is in 100 guilds.
  class MissingIntentError < Error
    def initialize(message = nil)
      super(message || <<~MSG.strip)
        Discord refused the search request. GET /guilds/{id}/messages/search is
        gated on the MESSAGE_CONTENT privileged intent, which is off by default
        and has to be enabled for the application in the Developer Portal, under
        Bot -> Privileged Gateway Intents. Past 100 guilds Discord reviews the
        request by hand, and "I am using it as a database" is not a use case it
        approves.

        Everything else in this library works without the intent. Search is the
        only part that needs it.
      MSG
    end
  end

  # An attempt to search outside the messages this bot wrote, while the
  # own_messages_only guard is on.
  #
  # Search is the one endpoint in Discord's API that could turn this library
  # into a scraper: it reads across a whole guild rather than a channel this bot
  # was pointed at. The guard is enforced by pinning author_id to our own
  # application, and this is what you get for trying to unpin it.
  class SearchScopeError < Error; end
end
