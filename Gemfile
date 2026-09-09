# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"

group :test do
  gem "minitest", "~> 6.0"
  gem "sqlite3", "~> 2.0"
end

# The Rails integrations are optional at runtime -- the gem itself depends on no
# part of Rails -- and these are here only so their adapters can be tested.
#
# Declared at the top level rather than inside a group because that is the only
# place Appraisal will substitute a version: gems nested in a group are appended
# to, not replaced, and Bundler then refuses the duplicate. See Appraisals.
gem "activerecord", ">= 7.2"
gem "activestorage", ">= 7.2"

group :development do
  gem "appraisal", "~> 2.5"
  gem "rubocop", "~> 1.60"
  gem "rubocop-minitest", "~> 0.34"
  gem "rubocop-rake", "~> 0.6"
end
