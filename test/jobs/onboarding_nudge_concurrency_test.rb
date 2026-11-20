require "test_helper"
require "mocha/minitest"
require "timeout"

class OnboardingNudgeConcurrencyTest < ActiveJob::TestCase
  self.use_transactional_tests = false

  setup do
    travel_to Time.utc(2026, 11, 21, 15)
    @user = User.create!(telegram_id: 97731, first_private_start_at: 25.hours.ago, last_seen_at: 25.hours.ago)
    @list = @user.wishlists.create!(title: "Birthday")
    @nudge = OnboardingNudge.create!(user: @user, locale: "ru")
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = "local-onboarding-test"
    GiftSuggestion.stubs(:enabled?).returns(true)
  end

  teardown do
    @user.destroy!
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    travel_back
  end

  test "two workers generate and deliver only one reminder" do
    started = Queue.new
    release = Queue.new
    messages = Queue.new
    generator = Object.new
    generator.define_singleton_method(:call) do |*_args|
      started << true
      Timeout.timeout(5) { release.pop }
      [ "Lamp", "Board game", "Mug" ]
    end
    api = Object.new
    api.define_singleton_method(:send_message) { |**params| messages << params }
    YandexAi::GiftIdeas.stubs(:new).returns(generator)
    Telegram::Bot::Client.stubs(:new).returns(stub(api: api))

    first = run_worker
    Timeout.timeout(5) { started.pop }
    second = run_worker
    Timeout.timeout(5) { second.value }
    assert_equal 0, messages.size
    release << true
    Timeout.timeout(5) { first.value }

    assert_equal 1, messages.size
    assert_equal 1, GiftSuggestion.where(user: @user).count
    assert_equal 0, started.size
    assert_equal 1, @nudge.reload.attempts
    assert @nudge.sent_at
  ensure
    release << true
    [ first, second ].compact.each(&:join)
  end

  test "automatic and personal generation share the two-worker concurrency group" do
    assert_equal GiftIdeasJob.new.concurrency_key, OnboardingNudgeJob.new.concurrency_key
    assert_equal 2, OnboardingNudgeJob.concurrency_limit
  end

  private

  def run_worker
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        OnboardingNudgeJob.perform_now(@nudge.id)
      end
    end
  end
end
