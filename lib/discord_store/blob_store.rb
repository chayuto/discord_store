# frozen_string_literal: true

require "digest"
require "set"
require "stringio"

module DiscordStore
  # Stores arbitrary binary data as chunked message attachments.
  #
  # The hard problem here is not chunking, it is addressing. In late 2023
  # Discord began signing CDN links with an HMAC over an expiry timestamp, and
  # every project in this genre that had stored URLs in a database woke up to a
  # dead index roughly a day later. The community's answer was to stand up
  # caching proxies on Cloudflare Workers to re-resolve links on demand, which
  # works and which also concedes the entire premise: the storage is only free
  # if you ignore the server you now have to run.
  #
  # This library stores +channel_id+, +message_id+ and +attachment_id+, never a
  # URL, and re-resolves at read time. Rails users get the rest for free: an
  # ActiveStorage service in +proxy+ mode routes reads through
  # ActiveStorage::Blobs::ProxyController, which is the Cloudflare Worker
  # everybody rebuilt, already in the framework.
  class BlobStore
    # What a stored blob is made of.
    Manifest = Struct.new(:key, :byte_size, :checksum, :content_type, :chunks,
                          :channel_id, :message_id, keyword_init: true) do
      # @return [Integer]
      def chunk_count = chunks.size

      def to_h
        {
          "key" => key, "size" => byte_size, "sum" => checksum, "type" => content_type,
          "chunks" => chunks.map do |c|
            { "m" => c[:message_id], "a" => c[:attachment_id], "c" => c[:channel_id], "s" => c[:size] }
          end
        }
      end

      def self.from_h(hash, channel_id: nil, message_id: nil)
        new(
          key: hash["key"], byte_size: hash["size"], checksum: hash["sum"],
          content_type: hash["type"], channel_id: channel_id, message_id: message_id,
          chunks: Array(hash["chunks"]).map do |c|
            { message_id: c["m"], attachment_id: c["a"], channel_id: c["c"], size: c["s"] }
          end
        )
      end
    end

    MANIFEST_STREAM = "__manifest"

    attr_reader :config, :rest, :index

    # @param rest [Transport::REST]
    # @param config [Configuration]
    # @param index [#get, #put, #delete, nil] manifest index; defaults to one
    #   backed by the manifest channel itself
    def initialize(rest:, config:, index: nil)
      @rest = rest
      @config = config
      @cipher = Cipher.build(config)
      @limits = GuildLimits.new(rest: rest, config: config)
      blob_channels = config.blob_channel_ids.empty? ? config.log_channel_ids : config.blob_channel_ids
      @shard = ChannelShard.new(blob_channels)
      @manifest_log = Log.new(
        rest: rest, config: config,
        channel_ids: [config.manifest_channel_id || @shard.channel_ids.first]
      )
      @index = index || ManifestIndex.new(log: @manifest_log)
    end

    # @return [Integer] bytes per chunk, discovered from the guild
    def chunk_size = @limits.chunk_size

    # Stores +data+ under +key+, replacing anything already there.
    #
    # @param key [String]
    # @param data [String, IO]
    # @param content_type [String]
    # @param checksum [String, nil] expected MD5, base64; verified if given
    # @return [Manifest]
    def put(key, data, content_type: "application/octet-stream", checksum: nil)
      io = data.respond_to?(:read) ? data : StringIO.new(data.to_s.dup.force_encoding(Encoding::BINARY))
      channel_id = @shard.for(key)

      chunks = []
      digest = Digest::MD5.new
      total = 0

      each_chunk(io) do |bytes, ordinal|
        digest << bytes
        total += bytes.bytesize
        chunks << upload_chunk(channel_id, key, ordinal, bytes)
      end

      computed = [digest.digest].pack("m0")

      if checksum && checksum != computed
        chunks.each { |chunk| safe_delete(chunk[:channel_id], chunk[:message_id]) }
        raise Error, "checksum mismatch for #{key}: expected #{checksum}, computed #{computed}"
      end

      manifest = Manifest.new(key: key, byte_size: total, checksum: computed,
                              content_type: content_type, chunks: chunks, channel_id: channel_id)

      previous = @index.get(key)
      @index.put(key, manifest)
      retire(previous) if previous

      manifest
    end

    # Chunks that no live manifest points at.
    #
    # A blob is a manifest plus its chunks, written in that order and deleted in
    # the other. Anything that interrupts the middle -- a crash, a rate limit
    # that outlived its retries, a delete that got halfway -- leaves chunks with
    # nothing referring to them. They are invisible to every other method here,
    # because every other method starts from a manifest, and they count against
    # the guild's storage forever.
    #
    # Finding them means asking a question no channel scan answers well: which
    # attachments exist that nothing references. Discord's search can answer it
    # directly, filtering on an extension that is already public and says
    # nothing about the contents.
    #
    # Costs one search page per 25 chunks and needs the MESSAGE_CONTENT intent.
    #
    # @param search [Search, nil] defaults to one built from this config
    # @return [Array<Hash>] each {message_id:, channel_id:, filename:, size:}
    # @raise [MissingIntentError] if the privileged intent is not enabled
    def orphans(search: nil)
      finder = search || Search.new(rest: @rest, config: @config)
      referenced = referenced_message_ids

      found = []
      finder.each(has: "file",
                  attachment_extension: Search::EXTENSION,
                  channel_ids: @config.blob_channel_ids) do |message|
        next if referenced.include?(message["id"].to_s)

        Array(message["attachments"]).each do |attachment|
          # Spilled log records share the extension and are not blob chunks.
          next if attachment["filename"].to_s == Codec::SPILL_FILENAME

          found << { message_id: message["id"].to_s, channel_id: message["channel_id"].to_s,
                     filename: attachment["filename"].to_s, size: attachment["size"].to_i }
        end
      end

      found
    end

    # @param key [String]
    # @return [String] the blob's bytes
    # @raise [NotFoundError]
    def get(key)
      manifest = fetch_manifest!(key)
      buffer = +""
      buffer.force_encoding(Encoding::BINARY)
      each_chunk_body(manifest) { |bytes| buffer << bytes }
      buffer
    end

    # Streams the blob without holding all of it.
    #
    # @param key [String]
    # @yieldparam bytes [String]
    # @return [void]
    def download(key, &)
      each_chunk_body(fetch_manifest!(key), &)
    end

    # Reads a byte range.
    #
    # Only the chunks the range touches are fetched, so a range read of a large
    # blob costs a couple of requests rather than all of them. Whether the CDN
    # honours an HTTP Range header on top of that is a bonus, not a dependency.
    #
    # @param key [String]
    # @param range [Range]
    # @return [String]
    def get_range(key, range)
      manifest = fetch_manifest!(key)
      first, last = clamp_range(range, manifest.byte_size)
      return +"" if first > last

      out = +""
      out.force_encoding(Encoding::BINARY)
      offset = 0

      manifest.chunks.each_with_index do |chunk, ordinal|
        chunk_first = offset
        chunk_last = offset + chunk[:size] - 1
        offset += chunk[:size]

        next if chunk_last < first
        break if chunk_first > last

        bytes = fetch_chunk(manifest.key, ordinal, chunk)
        from = [first - chunk_first, 0].max
        to = [last - chunk_first, bytes.bytesize - 1].min
        out << bytes.byteslice(from, to - from + 1).to_s
      end

      out
    end

    # @param key [String]
    # @return [Boolean]
    def exist?(key) = !@index.get(key).nil?

    # @param key [String]
    # @return [Integer, nil] byte size, without fetching the data
    def size(key) = @index.get(key)&.byte_size

    # @param key [String]
    # @return [void]
    def delete(key)
      manifest = @index.get(key)
      return if manifest.nil?

      retire(manifest)
      @index.delete(key)
      nil
    end

    # Deletes every blob whose key starts with +prefix+.
    #
    # @param prefix [String]
    # @return [Integer] how many were deleted
    def delete_prefix(prefix)
      keys = @index.keys.select { |key| key.start_with?(prefix) }
      keys.each { |key| delete(key) }
      keys.size
    end

    # A freshly signed CDN URL for the blob.
    #
    # Only possible for a single-chunk blob: a blob split across attachments has
    # no single URL, and there is no way to make one without a server that
    # concatenates the pieces. That is the whole argument for proxy mode.
    #
    # @param key [String]
    # @return [String]
    # @raise [Error] if the blob has more than one chunk
    def url(key)
      manifest = fetch_manifest!(key)

      if manifest.chunk_count != 1
        raise Error,
              "blob #{key} spans #{manifest.chunk_count} attachments and has no single URL. " \
              "Configure the ActiveStorage service with a proxy route, or store smaller objects."
      end

      resolve_urls(manifest.chunks).fetch(manifest.chunks.first[:attachment_id])
    end

    private

    # Normalises inclusive, exclusive and endless ranges against the real size.
    #
    # @return [Array(Integer, Integer)] inclusive first and last byte offsets
    def clamp_range(range, byte_size)
      first = [range.begin.to_i, 0].max

      last = if range.end.nil?
               byte_size - 1
             elsif range.exclude_end?
               range.end.to_i - 1
             else
               range.end.to_i
             end

      [first, [last, byte_size - 1].min]
    end

    def each_chunk(io)
      ordinal = 0
      size = chunk_size

      while (bytes = io.read(size))
        break if bytes.empty?

        yield bytes.dup.force_encoding(Encoding::BINARY), ordinal
        ordinal += 1
      end
    end

    def upload_chunk(channel_id, key, ordinal, bytes)
      payload = @cipher.seal_binary(bytes, aad: "#{key}/#{ordinal}")

      message = @rest.create_message(
        channel_id,
        content: "DS1 blob #{ordinal}",
        nonce: Digest::SHA256.hexdigest("#{key}/#{ordinal}/#{bytes.bytesize}")[0, 24],
        files: [{ filename: "#{ordinal}.ds1", content: payload, content_type: "application/octet-stream" }]
      )

      attachment = message["attachments"].first
      raise Error, "Discord accepted chunk #{ordinal} of #{key} but returned no attachment" unless attachment

      { message_id: message["id"], attachment_id: attachment["id"],
        channel_id: channel_id, size: bytes.bytesize, ordinal: ordinal }
    end

    def each_chunk_body(manifest)
      manifest.chunks.each_with_index do |chunk, ordinal|
        yield decrypt_chunk(manifest.key, ordinal, fetch_chunk_raw(chunk))
      end
    end

    # The chunk's ordinal is its position in the manifest, not a stored field:
    # it is bound into the encryption AAD, so a chunk that is reordered or
    # swapped between blobs fails to authenticate rather than decoding as
    # plausible-looking garbage.
    def fetch_chunk(key, ordinal, chunk)
      decrypt_chunk(key, ordinal, fetch_chunk_raw(chunk))
    end

    def fetch_chunk_raw(chunk)
      urls = resolve_urls([chunk])
      url = urls[chunk[:attachment_id]]
      raise NotFoundError.new("attachment #{chunk[:attachment_id]} is gone", status: 404) unless url

      @rest.download(url)
    end

    def decrypt_chunk(key, ordinal, payload)
      return payload unless @cipher.encrypting?

      @cipher.open_binary(payload, aad: "#{key}/#{ordinal}")
    end

    # Re-resolves attachment URLs by re-reading the messages that hold them.
    #
    # Chunks written together land in consecutive messages, so one paginated
    # range read usually resolves the whole blob at a hundred attachments per
    # request instead of one. Sparse or interleaved chunks fall back to
    # individual fetches rather than paging a channel indefinitely.
    #
    # @param chunks [Array<Hash>]
    # @return [Hash{String => String}] attachment_id => fresh URL
    def resolve_urls(chunks)
      wanted = chunks.to_h { |chunk| [chunk[:attachment_id].to_s, chunk] }
      by_channel = chunks.group_by { |chunk| chunk[:channel_id] }
      resolved = {}

      by_channel.each do |channel_id, channel_chunks|
        scan_range(channel_id, channel_chunks, wanted, resolved) if channel_chunks.size > 1
        resolve_individually(channel_id, channel_chunks, wanted, resolved)
      end

      resolved
    end

    # One paginated sweep over the ID range the chunks occupy. Chunks written
    # together are consecutive, so this usually resolves a whole blob at a
    # hundred attachments per request.
    def scan_range(channel_id, chunks, wanted, resolved)
      ids = chunks.map { |chunk| chunk[:message_id].to_i }
      cursor = (ids.min - 1).to_s
      highest = ids.max

      # Bounded, so interleaved or sparse chunks fall back rather than paging a
      # busy channel indefinitely.
      page_budget = [(chunks.size / 100.0).ceil * 2, 2].max

      page_budget.times do
        page = @rest.list_messages(channel_id, after: cursor, limit: 100)
        break if page.empty?

        page.each { |message| harvest(message, wanted, resolved) }
        cursor = page.map { |message| message["id"].to_i }.max.to_s
        break if cursor.to_i >= highest
      end
    end

    def resolve_individually(channel_id, chunks, wanted, resolved)
      chunks.each do |chunk|
        next if resolved.key?(chunk[:attachment_id].to_s)

        harvest(@rest.get_message(channel_id, chunk[:message_id]), wanted, resolved)
      end
    end

    def harvest(message, wanted, resolved)
      Array(message["attachments"]).each do |attachment|
        id = attachment["id"].to_s
        resolved[id] = attachment["url"] if wanted.key?(id)
      end
    end

    def fetch_manifest!(key)
      @index.get(key) || raise(NotFoundError.new("no blob stored under #{key.inspect}", status: 404))
    end

    def retire(manifest)
      case config.delete_policy
      when :tombstone
        # Cheapest and safest: the bytes stay, the index forgets them. Storage is
        # not reclaimed, which on somebody else's infrastructure is a choice
        # worth making deliberately.
        nil
      else
        manifest.chunks.group_by { |chunk| chunk[:channel_id] }.each do |channel_id, chunks|
          @rest.bulk_delete_messages(channel_id, chunks.map { |chunk| chunk[:message_id] })
        end
      end
    end

    def referenced_message_ids
      @index.warm!
      @index.keys.each_with_object(Set.new) do |key, ids|
        manifest = @index.get(key)
        next if manifest.nil?

        manifest.chunks.each { |chunk| ids << chunk[:message_id].to_s }
      end
    end

    def safe_delete(channel_id, message_id)
      @rest.delete_message(channel_id, message_id)
    rescue APIError
      nil
    end

    # Maps blob keys to manifests.
    #
    # A lookup by key would otherwise mean scanning a channel. This scans it
    # exactly once, at first use, and keeps the result. Manifests are one small
    # message per blob, so the scan is a hundred blobs per request.
    #
    # Discord's message search could answer a key lookup directly, but only if
    # the key were stored in plaintext, and a blob key names the thing it holds.
    # Scanning once is cheaper than telling Discord what our files are called.
    #
    # Swap in your own if you would rather the index lived in Postgres: anything
    # answering get/put/delete/keys will do.
    class ManifestIndex
      def initialize(log:)
        @log = log
        @entries = {}
        @warm = false
        @mutex = Mutex.new
      end

      # @param key [String]
      # @return [Manifest, nil]
      def get(key)
        warm!
        @mutex.synchronize { @entries[key.to_s] }
      end

      # @return [Array<String>]
      def keys
        warm!
        @mutex.synchronize { @entries.keys }
      end

      # @param key [String]
      # @param manifest [Manifest]
      # @return [Manifest]
      def put(key, manifest)
        warm!
        record = @log.append(stream: MANIFEST_STREAM, data: manifest.to_h)
        @mutex.synchronize { @entries[key.to_s] = manifest.tap { |m| m.message_id = record.lsn } }
      end

      # @param key [String]
      # @return [void]
      def delete(key)
        warm!
        @log.append(stream: MANIFEST_STREAM, data: { "key" => key.to_s, "__deleted" => true })
        @mutex.synchronize { @entries.delete(key.to_s) }
        nil
      end

      # Replays the manifest channel. Later records win, so a rewrite or a
      # delete simply appends and the last word stands.
      #
      # @param force [Boolean]
      # @return [Integer] number of live manifests
      def warm!(force: false)
        @mutex.synchronize do
          return @entries.size if @warm && !force

          @entries.clear

          @log.each(stream: MANIFEST_STREAM) do |record|
            data = record.data
            next unless data.is_a?(Hash)

            if data["__deleted"]
              @entries.delete(data["key"].to_s)
            elsif data["key"]
              @entries[data["key"].to_s] =
                Manifest.from_h(data, channel_id: record.channel_id, message_id: record.lsn)
            end
          end

          @warm = true
          @entries.size
        end
      end
    end
  end
end
