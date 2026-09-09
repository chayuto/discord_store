# frozen_string_literal: true

module DiscordStore
  # Process-wide settings. Most applications configure this once at boot:
  #
  #   DiscordStore.configure do |c|
  #     c.i_understand_this_violates_discord_tos = true
  #     c.token       = ENV.fetch("DISCORD_BOT_TOKEN")
  #     c.application_id = ENV.fetch("DISCORD_APPLICATION_ID")
  #     c.guild_id    = ENV.fetch("DISCORD_GUILD_ID")
  #     c.secret_key  = ENV.fetch("DISCORD_STORE_KEY") # 32 raw bytes, base64
  #   end
  class Configuration
    # Discord's documented global ceiling for a bot token, in requests/second.
    # We aim below it by default; see #global_rate_limit.
    DISCORD_GLOBAL_LIMIT = 50

    # Maximum characters in a normal message's +content+ field.
    MESSAGE_CONTENT_LIMIT = 2000

    # Every setting that has a sensible default, and its default.
    DEFAULTS = {
      global_rate_limit: 45,
      quota_timeout: 15.0,
      max_retries: 5,
      # Discord answers 202 with retry_after 0 when it has no better estimate,
      # and says to "retry after a short delay". This is what short means.
      # Tests drop it so the suite exercises the retry rather than sleeping
      # through it, which is the same reason the fake's rate limit is settable.
      search_retry_floor: 0.5,
      open_timeout: 5.0,
      read_timeout: 30.0,
      write_timeout: 30.0,
      user_agent: nil,
      api_base: "https://discord.com/api/v10",
      cipher: :aes_256_gcm,
      content_budget: 1900,
      max_concurrent_transfers: 24,
      chunk_size: nil,
      delete_policy: :tombstone,
      own_messages_only: true,
      logger: nil
    }.freeze

    # --- Acknowledgement -----------------------------------------------------

    # Storing application data in Discord messages violates the Discord
    # Developer Terms of Service. Nothing in this library will make a network
    # request until this is explicitly set to true.
    attr_accessor :i_understand_this_violates_discord_tos

    # --- Credentials and placement -------------------------------------------

    # Bot token, without the "Bot " prefix.
    attr_accessor :token

    # The bot's application (user) ID. Used to enforce that we only ever read
    # messages our own bot wrote. Strongly recommended; see #own_messages_only.
    attr_accessor :application_id

    # The guild that owns the channels we write to.
    attr_accessor :guild_id

    # Channels used for the append-only log. More than one channel multiplies
    # write throughput, because Discord's harshest message limit is per-channel.
    attr_accessor :log_channel_ids

    # Channel used for mutable documents (the KV layer).
    attr_accessor :document_channel_id

    # Channels used for blob chunks (ActiveStorage). Sharded like the log.
    attr_accessor :blob_channel_ids

    # Channel holding blob manifests. Kept separate from chunks so that a
    # manifest scan does not have to page past gigabytes of chunk messages.
    attr_accessor :manifest_channel_id

    # --- Crypto --------------------------------------------------------------

    # 32 raw bytes, base64-encoded. Required unless +cipher+ is :none.
    attr_accessor :secret_key

    # :aes_256_gcm (default) or :none. :none writes readable JSON into the
    # channel, which is useful when you want humans to read the data in the
    # Discord client, and which forfeits the encryption-at-rest that Discord's
    # own developer terms require of anyone storing end-user data.
    attr_accessor :cipher

    # --- Transport -----------------------------------------------------------

    attr_accessor :global_rate_limit, :quota_timeout, :max_retries,
                  :open_timeout, :read_timeout, :write_timeout,
                  :user_agent, :api_base, :logger, :search_retry_floor

    # Refuse to read any message not authored by +application_id+. This is the
    # line between a storage backend and a scraper, and it is enforced in code
    # rather than in documentation. Leave it on.
    attr_accessor :own_messages_only

    # --- Encoding ------------------------------------------------------------

    # How many characters of a message's content we are willing to fill. Kept
    # under MESSAGE_CONTENT_LIMIT so that framing overhead can never push a
    # message over the hard limit.
    attr_accessor :content_budget

    # Concurrency ceiling for blob chunk transfers.
    attr_accessor :max_concurrent_transfers

    # Bytes per blob chunk. Left nil to be discovered at runtime from the
    # guild's boost tier, because Discord's attachment ceiling has moved
    # several times and hardcoding it is how these libraries break.
    attr_accessor :chunk_size

    # What to do when a blob or record is deleted:
    #
    #   :tombstone  — edit the message to a tombstone marker, never delete.
    #                 Cheapest, and survives the 14-day bulk-delete window.
    #   :bulk       — bulk-delete where possible, tombstone the rest.
    #   :aggressive — delete everything, one request at a time if we must.
    attr_accessor :delete_policy

    def initialize
      DEFAULTS.each { |name, value| public_send(:"#{name}=", value) }
      @i_understand_this_violates_discord_tos = false
      @log_channel_ids = []
      @blob_channel_ids = []
    end

    # @raise [UnacknowledgedError] if the ToS acknowledgement is missing
    # @raise [ConfigurationError] if a required setting is missing or invalid
    # @return [void]
    def validate!
      raise UnacknowledgedError unless i_understand_this_violates_discord_tos
      raise ConfigurationError, "token is required" if blank?(token)

      if own_messages_only && blank?(application_id)
        raise ConfigurationError,
              "application_id is required while own_messages_only is enabled " \
              "(it is what makes the check possible). Set it, or explicitly " \
              "set own_messages_only = false and accept what that means."
      end

      validate_cipher!
      validate_budget!
      self
    end

    # The raw 32-byte encryption key.
    #
    # @return [String, nil]
    def secret_key_bytes
      return nil if cipher == :none
      return nil if blank?(secret_key)

      require "base64"
      Base64.strict_decode64(secret_key.to_s)
    rescue ArgumentError
      raise ConfigurationError, "secret_key is not valid base64"
    end

    # Every channel this configuration knows about, deduplicated.
    #
    # @return [Array<String>]
    def all_channel_ids
      [
        *log_channel_ids,
        *blob_channel_ids,
        document_channel_id,
        manifest_channel_id
      ].compact.map(&:to_s).uniq
    end

    private

    def validate_cipher!
      unless %i[aes_256_gcm none].include?(cipher)
        raise ConfigurationError, "cipher must be :aes_256_gcm or :none, got #{cipher.inspect}"
      end
      return if cipher == :none

      raise ConfigurationError, "secret_key is required unless cipher is :none" if blank?(secret_key)

      bytes = secret_key_bytes
      return if bytes && bytes.bytesize == 32

      raise ConfigurationError,
            "secret_key must decode to exactly 32 bytes, got #{bytes ? bytes.bytesize : 0}"
    end

    def validate_budget!
      return if content_budget.positive? && content_budget < MESSAGE_CONTENT_LIMIT

      raise ConfigurationError,
            "content_budget must be between 1 and #{MESSAGE_CONTENT_LIMIT - 1}"
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
