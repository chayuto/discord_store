# frozen_string_literal: true

require_relative "discord_store/version"
require_relative "discord_store/errors"
require_relative "discord_store/snowflake"
require_relative "discord_store/configuration"
require_relative "discord_store/cipher"
require_relative "discord_store/channel_shard"
require_relative "discord_store/codec"
require_relative "discord_store/log"
require_relative "discord_store/guild_limits"
require_relative "discord_store/blob_store"
require_relative "discord_store/kv"
require_relative "discord_store/transport/http"
require_relative "discord_store/transport/quota"
require_relative "discord_store/transport/bucket"
require_relative "discord_store/transport/rate_limiter"
require_relative "discord_store/transport/rest"
require_relative "discord_store/transport/fake"

# Uses Discord as a database.
#
# It works, in the sense that the data goes in and comes back out. It is also an
# explicit violation of the Discord Developer Terms of Service, it is capped at
# a few megabytes per second by rate limits nobody can raise for you, and every
# byte of it lives at the pleasure of a company that has already shipped one
# change (signed, expiring CDN links) that broke this entire category of project
# overnight.
#
# Read {Configuration#i_understand_this_violates_discord_tos} before using it.
module DiscordStore
  class << self
    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # @yieldparam config [Configuration]
    # @return [Configuration]
    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Resets configuration and any memoized client. Mainly for tests.
    #
    # @return [void]
    def reset!
      @configuration = nil
      @client = nil
    end

    # The process-wide client.
    #
    # @return [Client]
    def client
      @client ||= Client.new(config: configuration)
    end

    # Replaces the process-wide client, e.g. with one wired to the fake.
    #
    # @param client [Client]
    # @return [Client]
    attr_writer :client

    # @return [String] a fresh base64 encryption key
    def generate_key = Cipher.generate_key
  end

  # Ties the layers together: one transport, one rate limiter, and the stores
  # built on top of them.
  class Client
    attr_reader :config, :rest

    # @param config [Configuration]
    # @param http [#call, nil] injectable HTTP backend; pass a
    #   {Transport::Fake} to run the whole stack without a token
    def initialize(config: DiscordStore.configuration, http: nil)
      @config = config.validate!
      @rest = Transport::REST.new(config: @config, http: http)
    end

    # @return [Log]
    def log
      @log ||= Log.new(rest: @rest, config: @config)
    end

    # @return [BlobStore]
    def blobs
      @blobs ||= BlobStore.new(rest: @rest, config: @config)
    end

    # @return [KV]
    def kv
      @kv ||= KV.new(rest: @rest, config: @config)
    end

    # @return [GuildLimits]
    def limits
      @limits ||= GuildLimits.new(rest: @rest, config: @config)
    end

    # Confirms the token works and that the configured application_id matches
    # the token's actual identity. Worth calling at boot: a mismatched
    # application_id silently makes every read return nothing, because the
    # own-messages guard rejects our own writes.
    #
    # @return [Hash] the bot user
    # @raise [ConfigurationError] on an application_id mismatch
    def verify!
      user = @rest.current_user

      if @config.own_messages_only && user["id"].to_s != @config.application_id.to_s
        raise ConfigurationError,
              "configured application_id #{@config.application_id.inspect} is not this token's " \
              "identity (#{user["id"].inspect}). Every read would silently return nothing."
      end

      user
    end

    # @return [void]
    def close = @rest.close
  end
end
