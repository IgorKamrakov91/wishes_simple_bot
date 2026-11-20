class OnboardingNudgesJob < ApplicationJob
  queue_as :reminders

  def perform
    return if OnboardingNudge.next_send_at(Time.current) > Time.current

    OnboardingNudge.candidates.find_each do |user|
      nudge = OnboardingNudge.find_or_create_by!(user_id: user.id) { |row| row.locale = I18n.locale.to_s }
      OnboardingNudgeJob.perform_later(nudge.id) if OnboardingNudge.ready.exists?(nudge.id)
    end
  end
end
