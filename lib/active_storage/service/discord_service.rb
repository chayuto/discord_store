# frozen_string_literal: true

require "discord_store"
require "tempfile"

module ActiveStorage
  class Service
    # An ActiveStorage service backed by Discord message attachments.
    #
    #   # config/storage.yml
    #   discord:
    #     service: Discord
    #     token: <%= ENV["DISCORD_BOT_TOKEN"] %>
    #     application_id: <%= ENV["DISCORD_APPLICATION_ID"] %>
    #     guild_id: <%= ENV["DISCORD_GUILD_ID"] %>
    #     secret_key: <%= ENV["DISCORD_STORE_KEY"] %>
    #     blob_channel_ids: ["...", "..."]
    #     manifest_channel_id: "..."
    #     i_understand_this_violates_discord_tos: true
    #
    # Configure the service to be proxied, not redirected:
    #
    #   # config/environments/production.rb
    #   config.active_storage.resolve_model_to_route = :rails_storage_proxy
    #
    # That line is the whole point of building this on Rails rather than from
    # scratch.
    #
    # When Discord began signing CDN links with an expiring HMAC at the end of
    # 2023, every Discord-backed filesystem that had stored URLs broke about a
    # day later, and the community's fix was to deploy caching proxies on
    # Cloudflare Workers that re-fetch the message and hand back a fresh link.
    # ActiveStorage has shipped that proxy for years — it is
    # ActiveStorage::Blobs::ProxyController — and in proxy mode reads go through
    # it, so the URL a browser sees is a Rails URL that never expires and the
    # Discord link is re-resolved per request, server-side, where it belongs.
    #
    # Redirect mode works only for blobs small enough to be a single attachment,
    # because a blob split across attachments has no single URL to redirect to.
    class DiscordService < Service
      # What every other ActiveStorage service yields per iteration when
      # streaming a download. Not a Discord number -- a Rails one.
      STREAM_CHUNK_SIZE = 5 * 1024 * 1024

      attr_reader :client, :blobs

      # @param config [Hash] the storage.yml stanza, symbolized
      def initialize(**config)
        @config = config
        # +http+ is a test seam, the same one S3Service exposes as +client+:
        # it lets the conformance suite run the whole service against an
        # in-memory Discord. Nothing in storage.yml sets it.
        @client = DiscordStore::Client.new(
          config: build_configuration(config), http: config[:http]
        )
        @blobs = @client.blobs
        super()
      end

      # @return [void]
      def upload(key, io, checksum: nil, content_type: nil, **)
        instrument :upload, key: key, checksum: checksum do
          @blobs.put(key, io, content_type: content_type || "application/octet-stream",
                              checksum: checksum)
        end
      rescue DiscordStore::Error => e
        raise ActiveStorage::IntegrityError, e.message if e.message.include?("checksum")

        raise
      end

      # @return [String, void]
      def download(key, &block)
        if block
          instrument :streaming_download, key: key do
            stream(key, &block)
          end
        else
          instrument :download, key: key do
            @blobs.get(key)
          end
        end
      rescue DiscordStore::NotFoundError
        raise ActiveStorage::FileNotFoundError
      end

      # Concatenates several blobs into one.
      #
      # S3 and GCS compose server-side; Discord cannot, so this reads the
      # sources and writes a new blob. It goes through a Tempfile rather than a
      # String because the inputs are attachments and composing four of them at
      # a 100 MiB tier would otherwise put 400 MiB on the heap.
      #
      # +filename+ and +disposition+ are accepted and dropped: Discord stores no
      # per-object metadata, and this service serves downloads through the
      # application anyway, which is where those two get applied.
      #
      # @return [void]
      def compose(source_keys, destination_key, content_type: nil, **)
        instrument :compose, key: destination_key, source_keys: source_keys do
          Tempfile.create(["discord-store-compose", ".bin"]) do |scratch|
            scratch.binmode
            source_keys.each { |source_key| @blobs.download(source_key) { |bytes| scratch.write(bytes) } }
            scratch.rewind
            @blobs.put(destination_key, scratch,
                       content_type: content_type || "application/octet-stream")
          end
        end
      end

      # @param key [String]
      # @param range [Range]
      # @return [String]
      def download_chunk(key, range)
        instrument :download_chunk, key: key, range: range do
          @blobs.get_range(key, range)
        end
      rescue DiscordStore::NotFoundError
        raise ActiveStorage::FileNotFoundError
      end

      # @return [void]
      def delete(key)
        instrument :delete, key: key do
          @blobs.delete(key)
        end
      end

      # @return [void]
      def delete_prefixed(prefix)
        instrument :delete_prefixed, prefix: prefix do
          @blobs.delete_prefix(prefix)
        end
      end

      # @return [Boolean]
      def exist?(key)
        instrument :exist, key: key do |payload|
          payload[:exist] = @blobs.exist?(key)
        end
      end

      # Discord has no pre-signed upload endpoint, so a browser cannot PUT
      # straight to it. Every byte goes through the application.
      def url_for_direct_upload(*, **)
        raise NotImplementedError,
              "Discord has no direct-upload endpoint. Uploads must pass through your " \
              "application, which also means they are bounded by your dyno's bandwidth " \
              "and by a rate limit measured in single-digit megabytes per second."
      end

      def headers_for_direct_upload(*, **) = {}

      private

      # Redirect mode: hand back a freshly signed CDN link.
      #
      # Only viable for a single-chunk blob. Anything larger has no single URL,
      # and there is no honest way to invent one — which is why proxy mode is
      # the documented configuration.
      def private_url(key, expires_in: nil, filename: nil, content_type: nil, disposition: nil, **)
        @blobs.url(key)
      rescue DiscordStore::Error => e
        raise ActiveStorage::FileNotFoundError if e.is_a?(DiscordStore::NotFoundError)

        raise e.class, <<~MSG
          #{e.message}

          Set config.active_storage.resolve_model_to_route = :rails_storage_proxy so reads
          go through ActiveStorage::Blobs::ProxyController, which reassembles the chunks
          server-side and never hands an expiring Discord link to a browser.
        MSG
      end

      # Discord links are already time-limited by Discord, on Discord's schedule,
      # and nothing here can lengthen or shorten that.
      def public_url(key, **)
        raise NotImplementedError,
              "a Discord-backed service cannot be public: every CDN link Discord issues " \
              "expires on its own schedule, so there is no stable public URL to publish."
      end

      # ActiveStorage's services all hand back 5 MB slices when streaming, and
      # Rails' conformance suite asserts it exactly. Discord's chunks are sized
      # by the guild's attachment ceiling instead -- 8 MiB to 100 MiB depending
      # on boost tier -- which is storage geometry and no business of a caller
      # iterating a download. Re-slice on the way out.
      def stream(key)
        buffer = (+"").force_encoding(Encoding::BINARY)

        @blobs.download(key) do |bytes|
          buffer << bytes
          yield buffer.slice!(0, STREAM_CHUNK_SIZE) while buffer.bytesize >= STREAM_CHUNK_SIZE
        end

        yield buffer unless buffer.empty?
      end

      def build_configuration(options)
        DiscordStore::Configuration.new.tap do |config|
          apply_credentials(config, options)
          apply_placement(config, options)
          apply_behaviour(config, options)
        end
      end

      def apply_credentials(config, options)
        config.i_understand_this_violates_discord_tos =
          options[:i_understand_this_violates_discord_tos]
        config.token = options[:token]
        config.application_id = options[:application_id]
        config.guild_id = options[:guild_id]
        config.secret_key = options[:secret_key]
        config.cipher = options[:cipher]&.to_sym || :aes_256_gcm
      end

      def apply_placement(config, options)
        config.blob_channel_ids = Array(options[:blob_channel_ids]).map(&:to_s)
        config.manifest_channel_id = options[:manifest_channel_id]&.to_s
        config.log_channel_ids = Array(options[:log_channel_ids]).map(&:to_s)
      end

      def apply_behaviour(config, options)
        config.chunk_size = options[:chunk_size]
        config.delete_policy = (options[:delete_policy] || :tombstone).to_sym
        config.max_concurrent_transfers =
          options[:max_concurrent_transfers] || config.max_concurrent_transfers
        config.logger = options[:logger]
      end
    end
  end
end
