# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"

group :test do
  gem "minitest", "~> 5.20"
  # The Rails integrations are optional at runtime and required for their tests.
  gem "activerecord", "~> 8.0"
  gem "activestorage", "~> 8.0"
  gem "sqlite3", "~> 2.0"
end

group :development do
  gem "rubocop", "~> 1.60"
  gem "rubocop-minitest", "~> 0.34"
  gem "rubocop-rake", "~> 0.6"
end
