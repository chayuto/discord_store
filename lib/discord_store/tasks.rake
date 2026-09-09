# frozen_string_literal: true

# Reports whether search works, without making its absence look like a failure:
# the MESSAGE_CONTENT intent is off by default and everything except orphan
# detection works fine without it.
def report_search(client)
  result = client.search.ours(limit: 1)
  puts "search:           available#{" (guild still indexing)" if result.indexing?}"
rescue DiscordStore::MissingIntentError
  puts "search:           unavailable (MESSAGE_CONTENT intent off; only rake discord:orphans needs it)"
rescue DiscordStore::IndexNotReadyError
  puts "search:           index not ready yet for this guild"
end

namespace :discord do
  desc "Rebuild the local database from the Discord log"
  task replay: :environment do
    connection = ActiveRecord::Base.connection

    unless connection.respond_to?(:replay!)
      abort "The current connection is not a discord adapter (it is #{connection.adapter_name})."
    end

    started = Time.now
    report = connection.replay!(from: ENV.fetch("FROM", nil))

    puts "replayed #{report[:applied]} transactions (#{report[:statements]} statements) " \
         "in #{(Time.now - started).round(1)}s"
    puts "cursor now #{report[:cursor]}"
    warn "#{report[:skipped]} transactions were skipped; see the log above" if report[:skipped].positive?
  end

  desc "Show how far the local database is behind the Discord log"
  task status: :environment do
    connection = ActiveRecord::Base.connection
    abort "not a discord adapter" unless connection.respond_to?(:log_status)

    status = connection.log_status
    puts "journal mode:  #{status[:mode]}"
    puts "local cursor:  #{status[:local_cursor] || "(never replayed)"}"
    puts "remote cursor: #{status[:remote_cursor] || "(empty log)"}"
    puts "buffered:      #{status[:pending]} transactions not yet written" if status[:pending].to_i.positive?

    if status[:local_cursor] == status[:remote_cursor]
      puts "up to date."
    else
      puts "behind. Run rake discord:replay."
    end
  end

  desc "Delete tombstoned records from a stream (STREAM=name, DRY_RUN=1)"
  task compact: :environment do
    stream = ENV.fetch("STREAM", nil) or abort "STREAM=name is required"
    dry_run = ENV["DRY_RUN"] == "1"

    report = DiscordStore.client.log.compact(stream: stream, dry_run: dry_run)

    puts "scanned #{report[:scanned]} records, #{report[:tombstoned]} tombstoned"
    if dry_run
      puts "(dry run; nothing deleted)"
    else
      puts "deleted #{report[:deleted]} messages"
      if report[:too_old].positive?
        puts "#{report[:too_old]} were older than the 14-day bulk-delete window and were left in " \
             "place. Re-run with delete_policy: :aggressive to remove them one request at a time."
      end
    end
  end

  desc "Generate an encryption key"
  task :key do
    puts DiscordStore.generate_key
  end

  desc "Check the token, the application id, and the channels"
  task doctor: :environment do
    client = DiscordStore.client
    user = client.verify!
    puts "token ok: #{user["id"]} (#{user["username"] || "bot"})"

    client.config.all_channel_ids.each do |channel_id|
      client.rest.get_channel(channel_id)
      puts "channel #{channel_id}: reachable"
    rescue DiscordStore::APIError => e
      puts "channel #{channel_id}: #{e.status} #{e.message}"
    end

    puts "attachment limit: #{client.limits.attachment_limit} bytes"
    puts "chunk size:       #{client.limits.chunk_size} bytes"

    report_search(client)
  rescue DiscordStore::Error => e
    abort "#{e.class}: #{e.message}"
  end

  desc "Find blob chunks that no manifest points at (needs MESSAGE_CONTENT)"
  task orphans: :environment do
    client = DiscordStore.client
    found = client.blobs.orphans

    if found.empty?
      puts "no orphaned chunks"
    else
      bytes = found.sum { |o| o[:size] }
      puts "#{found.size} orphaned chunk(s), #{bytes} bytes:"
      found.each { |o| puts "  #{o[:channel_id]}/#{o[:message_id]} #{o[:filename]} (#{o[:size]}b)" }
      puts
      puts "These are chunks whose manifest never landed or was half-deleted."
      puts "Nothing references them and nothing else will find them."
    end
  rescue DiscordStore::MissingIntentError => e
    abort e.message
  rescue DiscordStore::Error => e
    abort "#{e.class}: #{e.message}"
  end

  desc "Measure the real attachment ceiling by uploading test files (CHANNEL=id)"
  task probe: :environment do
    channel = ENV["CHANNEL"] || DiscordStore.client.config.blob_channel_ids.first
    abort "CHANNEL=id is required" unless channel

    puts "probing #{channel}; this uploads and deletes throwaway attachments..."
    limit = DiscordStore.client.limits.probe!(channel_id: channel)
    puts "largest accepted attachment: #{limit} bytes (#{(limit / 1024.0 / 1024).round(2)} MiB)"
    puts "pin it: config.chunk_size = #{limit - DiscordStore::GuildLimits::REQUEST_OVERHEAD}"
  end
end
