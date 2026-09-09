# frozen_string_literal: true

require "rails/railtie"

module DiscordStore
  # Loads the rake tasks and the adapter into a Rails application.
  #
  #   # Gemfile
  #   gem "discord_store", require: "discord_store/railtie"
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("tasks.rake", __dir__)
    end

    initializer "discord_store.adapter" do
      ActiveSupport.on_load(:active_record) do
        require "active_record/connection_adapters/discord_adapter"
      end
    end

    initializer "discord_store.active_storage" do
      ActiveSupport.on_load(:active_storage_blob) do
        require "active_storage/service/discord_service"
      end
    end
  end
end
