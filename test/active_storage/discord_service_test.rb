# frozen_string_literal: true

require "test_helper"
require "active_storage"
require "active_storage/service"
require "active_storage/errors"

# ActiveStorage autoloads its models through its engine. There is no engine
# here, so put that directory on the load path and require what the conformance
# suite touches by hand.
$LOAD_PATH.unshift File.join(Gem.loaded_specs.fetch("activestorage").full_gem_path, "app", "models")
require "active_storage/filename"
require "active_support/test_case"
require "active_storage/service/discord_service"
require "support/shared_service_tests"

# Rails' own conformance suite for storage services, pointed at this one.
#
# Everything else in this repository tests the library against expectations the
# library's author wrote down, which is a closed loop. This file is the one
# place where the expectations come from somewhere else entirely: if Discord is
# to be a storage backend, it has to satisfy the same contract Disk, S3, GCS and
# Azure satisfy, and that contract is defined by Rails, not here.
class DiscordServiceTest < ActiveSupport::TestCase
  include DiscordStore::TestSupport

  FAKE = DiscordStore::Transport::Fake.new(
    application_id: DiscordStore::TestSupport::APPLICATION_ID
  ).tap { |fake| fake.seed_guild("500") }

  SERVICE = ActiveStorage::Service::DiscordService.new(
    i_understand_this_violates_discord_tos: true,
    token: "fake-token",
    application_id: DiscordStore::TestSupport::APPLICATION_ID,
    guild_id: "500",
    secret_key: DiscordStore::Cipher.generate_key,
    blob_channel_ids: %w[3001],
    manifest_channel_id: "4001",
    http: FAKE
  )

  include ActiveStorage::Service::SharedServiceTests
end
