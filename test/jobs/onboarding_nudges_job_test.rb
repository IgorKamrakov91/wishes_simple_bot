require "test_helper"

class OnboardingNudgesJobTest < ActiveJob::TestCase
  setup do
    travel_to Time.utc(2026, 11, 21, 9)
    @user = User.create!(telegram_id: 97721, first_private_start_at: 25.hours.ago, last_seen_at: 25.hours.ago)
  end

  teardown { travel_back }

  test "only private inactive incomplete eligible users are scheduled and the row is unique" do
    User.create!(telegram_id: 97722, first_contact_kind: "inline_query", first_contact_at: 25.hours.ago)
    User.create!(telegram_id: 97723, first_private_start_at: 25.hours.ago, last_seen_at: 1.hour.ago)
    User.create!(telegram_id: 97724, first_private_start_at: 1.hour.ago, last_seen_at: 25.hours.ago)
    User.create!(telegram_id: 97725, first_private_start_at: 25.hours.ago, first_item_at: 24.hours.ago)
    User.create!(telegram_id: 97726, first_private_start_at: 25.hours.ago, onboarding_eligible: false)
    User.create!(telegram_id: 97727, first_private_start_at: 25.hours.ago, notify_onboarding: false)

    assert_enqueued_jobs 2, only: OnboardingNudgeJob do
      assert_difference("OnboardingNudge.count", 1) { 2.times { OnboardingNudgesJob.perform_now } }
    end
    assert_equal @user.id, OnboardingNudge.sole.user_id
    OnboardingNudge.sole.update!(claimed_at: Time.current)
    assert_no_enqueued_jobs { OnboardingNudgesJob.perform_now }
  end

  test "night and not-yet-due retries enqueue nothing" do
    OnboardingNudge.create!(user: @user, locale: "ru", retry_at: 1.hour.from_now)
    assert_no_enqueued_jobs { OnboardingNudgesJob.perform_now }
    travel_to Time.utc(2026, 11, 21, 17) do
      assert_no_enqueued_jobs { OnboardingNudgesJob.perform_now }
    end
  end

  test "sent and exhausted reminders are excluded while unfinished retries remain candidates" do
    [ { sent_at: 1.hour.ago }, { attempts: 3 }, { attempts: 4 } ].each_with_index do |attributes, index|
      user = User.create!(telegram_id: 97728 + index, first_private_start_at: 25.hours.ago, last_seen_at: 25.hours.ago)
      OnboardingNudge.create!(attributes.merge(user: user, locale: "ru"))
    end
    retry_user = User.create!(telegram_id: 97732, first_private_start_at: 25.hours.ago, last_seen_at: 25.hours.ago)
    OnboardingNudge.create!(user: retry_user, locale: "ru", attempts: 2, retry_at: 1.minute.ago)

    assert_equal [ @user.id, retry_user.id ].sort, OnboardingNudge.candidates.order(:id).pluck(:id)
    assert_enqueued_jobs 2, only: OnboardingNudgeJob do
      assert_difference("OnboardingNudge.count", 1) { OnboardingNudgesJob.perform_now }
    end
  end
end
