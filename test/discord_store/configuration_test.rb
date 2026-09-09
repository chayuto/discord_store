# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  include DiscordStore::TestSupport

  def test_refuses_to_run_without_the_acknowledgement
    config = build_config
    config.i_understand_this_violates_discord_tos = false

    error = assert_raises(DiscordStore::UnacknowledgedError) { config.validate! }
    assert_match(/Terms of Service/, error.message)
  end

  def test_requires_a_token
    config = build_config
    config.token = nil

    assert_raises(DiscordStore::ConfigurationError) { config.validate! }
  end

  def test_requires_an_application_id_while_the_guard_is_on
    config = build_config
    config.application_id = nil

    error = assert_raises(DiscordStore::ConfigurationError) { config.validate! }
    assert_match(/own_messages_only/, error.message)
  end

  def test_the_guard_can_be_turned_off_deliberately
    config = build_config
    config.application_id = nil
    config.own_messages_only = false

    assert_same config, config.validate!
  end

  def test_rejects_a_key_of_the_wrong_length
    config = build_config
    config.secret_key = Base64.strict_encode64("too short")

    assert_raises(DiscordStore::ConfigurationError) { config.validate! }
  end

  def test_rejects_a_key_that_is_not_base64
    config = build_config
    config.secret_key = "!!!not base64!!!"

    assert_raises(DiscordStore::ConfigurationError) { config.validate! }
  end

  def test_plaintext_mode_needs_no_key
    config = build_config
    config.cipher = :none
    config.secret_key = nil

    assert_same config, config.validate!
  end

  def test_content_budget_stays_under_the_hard_limit
    config = build_config
    config.content_budget = 2000

    assert_raises(DiscordStore::ConfigurationError) { config.validate! }
  end
end
