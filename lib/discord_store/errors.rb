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
end
