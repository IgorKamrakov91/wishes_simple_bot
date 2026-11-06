ENV["RAILS_ENV"] ||= "test"
require "simplecov"
SimpleCov.start "rails"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Screen text as written, without the blank line that widens screens
    def screen_text(text)
      text.to_s.delete_suffix("\n#{Bot::Context::SCREEN_WIDTH_LINE}")
    end
  end
end
