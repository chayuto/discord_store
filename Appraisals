# frozen_string_literal: true

# The Rails versions this gem claims to support.
#
# The floor is 7.2, and it is a hard one rather than a preference:
# ActiveRecord::ConnectionAdapters.register arrived in 7.2, and registering an
# adapter under 7.1 means defining a discord_connection factory method on
# ActiveRecord::Base instead. Supporting both is possible; claiming to support
# both without running the suite against both is not, so the floor is where the
# one registration path starts working.
#
#   bundle exec appraisal install   # regenerate gemfiles/
#   bundle exec appraisal rake      # run the suite against every version
#   BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle exec rake  # just one

appraise "rails-7.2" do
  gem "activerecord", "~> 7.2.0"
  gem "activestorage", "~> 7.2.0"
end

appraise "rails-8.0" do
  gem "activerecord", "~> 8.0.0"
  gem "activestorage", "~> 8.0.0"
end

appraise "rails-8.1" do
  gem "activerecord", "~> 8.1.0"
  gem "activestorage", "~> 8.1.0"
end
