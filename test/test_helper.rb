# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "discord_store"
require "minitest/autorun"

module DiscordStore
  # Wires the whole stack to an in-memory Discord.
  module TestSupport
    APPLICATION_ID = "111111111111111111"

    # Discord's real per-channel write window. Tests that care about the
    # limiter opt into it; everything else would just sleep.
    REAL_CHANNEL_LIMIT = { limit: 5, reset_after: 5.0 }.freeze

    # Discord's own "short delay" for an unindexed guild. Tests about the
    # retry itself want the logic, not the wait.
    REAL_SEARCH_RETRY_FLOOR = 0.5

    def build_fake(clock: nil, rate_limit: nil)
      options = {}
      options[:clock] = clock if clock
      options[:rate_limit] = rate_limit if rate_limit

      Transport::Fake.new(application_id: APPLICATION_ID, **options)
                     .tap { |fake| fake.seed_guild("500") }
    end

    def build_config(**overrides)
      Configuration.new.tap do |config|
        config.i_understand_this_violates_discord_tos = true
        config.token = "fake-token"
        config.application_id = APPLICATION_ID
        config.guild_id = "500"
        # One key per test, not per config: tests that rebuild a "fresh process"
        # against the same channel must be handed the same key, or they fail
        # for a reason that has nothing to do with what they are checking.
        config.secret_key = (@test_secret_key ||= Cipher.generate_key)
        config.search_retry_floor = 0.0
        config.log_channel_ids = %w[1001]
        config.document_channel_id = "2001"
        config.blob_channel_ids = %w[3001]
        config.manifest_channel_id = "4001"
        overrides.each { |key, value| config.public_send(:"#{key}=", value) }
      end
    end

    def build_client(fake = nil, **overrides)
      fake ||= build_fake
      [Client.new(config: build_config(**overrides), http: fake), fake]
    end
  end
end
