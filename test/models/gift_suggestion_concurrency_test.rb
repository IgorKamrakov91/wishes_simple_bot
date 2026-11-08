require "test_helper"
require "mocha/minitest"

# The app-wide daily cap holds when different people ask at the same moment
class GiftSuggestionConcurrencyTest < ActiveJob::TestCase
  self.use_transactional_tests = false

  KEYS = %w[YANDEX_AI_API_KEY YANDEX_AI_FOLDER_ID YANDEX_AI_ENABLED YANDEX_AI_DAILY_LIMIT].freeze

  setup do
    @previous_env = KEYS.to_h { |key| [ key, ENV[key] ] }
    ENV["YANDEX_AI_API_KEY"] = "key"
    ENV["YANDEX_AI_FOLDER_ID"] = "folder"
    ENV.delete("YANDEX_AI_ENABLED")
    ENV["YANDEX_AI_DAILY_LIMIT"] = "1"
    @users = [ 97301, 97302 ].map { |id| User.create!(telegram_id: id, first_name: "U#{id}") }
    @lists = @users.map { |user| user.wishlists.create!(title: "List") }
  end

  teardown do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    GiftSuggestion.where(user_id: @users.map(&:id)).delete_all
    @users.each(&:destroy!)
  end

  test "two people at once can't both pass a cap of one" do
    GiftSuggestion.where(created_at: Time.current.beginning_of_day - 1.day..).delete_all
    start = Concurrent::CyclicBarrier.new(2)
    # Both requests pause after counting; with the lock, the second one can't
    # count until the first has committed, so the pause just times out
    counted = Concurrent::CyclicBarrier.new(2)
    GiftSuggestion.stubs(:global_daily_limit).with { counted.wait(1); true }.returns(1)
    statuses = @users.zip(@lists).map do |user, list|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.wait
          GiftSuggestion.request_for!(User.find(user.id), list).status
        end
      end
    end.map(&:value)

    assert_equal %i[created global_limit], statuses.sort
    assert_equal 1, GiftSuggestion.where(user_id: @users.map(&:id)).count
  end
end
