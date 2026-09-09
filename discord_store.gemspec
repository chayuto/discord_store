# frozen_string_literal: true

require_relative "lib/discord_store/version"

Gem::Specification.new do |spec|
  spec.name = "discord_store"
  spec.version = DiscordStore::VERSION
  spec.authors = ["Chayut"]
  spec.email = ["chayut_o@hotmail.com"]

  spec.summary = "Use Discord as a database. Against your better judgement, and its Terms of Service."
  spec.description = <<~DESC
    A rate-limit-aware transport, an encrypted append-only log, an ActiveStorage
    service and an ActiveRecord adapter, all backed by Discord messages and
    attachments. Snowflake IDs as log sequence numbers, channels as partitions,
    tombstones instead of deletes, and CDN links re-resolved on every read
    instead of cached. An extended argument about what an ActiveRecord adapter
    is allowed to be, which happens to work.
  DESC

  spec.homepage = "https://github.com/chayuto/discord_store"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/discord_store"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.rake",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  # base64 leaves the default gems in Ruby 3.4; depend on it explicitly rather
  # than relying on it being there.
  spec.add_dependency "base64", "~> 0.2"
end
