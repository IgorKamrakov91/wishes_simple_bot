require "test_helper"
require "timeout"

class UserOnboardingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    User.where(telegram_id: 43001).destroy_all
  end

  test "simultaneous first updates return the same user inside webhook transactions" do
    ready = Queue.new
    start = Queue.new
    barrier = proc do |user|
      if user.telegram_id == 43001
        ready << true
        start.pop
      end
    end
    User.set_callback(:create, :before, barrier)

    requests = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.transaction do
            user = User.find_or_create_from_telegram(id: 43001, first_name: "Guest")
            # The outer webhook transaction remains usable after a collision.
            user.update!(last_seen_at: Time.current)
            user
          end
        end
      end
    end

    results = Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { start << true }
      requests.map(&:value)
    end

    assert_equal 1, User.where(telegram_id: 43001).count
    assert_equal 1, results.map(&:id).uniq.size
    assert results.all?(&:persisted?)
  ensure
    requests&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
    User.skip_callback(:create, :before, barrier) if barrier
  end
end
