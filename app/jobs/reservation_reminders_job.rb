# frozen_string_literal: true

class ReservationRemindersJob < ApplicationJob
  queue_as :reminders

  def perform
    User.where(reservation_reminder_days: [ 7, 14, 30 ])
      .where(reservation_reminder_next_at: ..Time.current).find_each.with_index do |user, index|
      ReservationReminderJob.set(wait: index.seconds).perform_later(user.id, user.reservation_reminder_next_at.iso8601(6))
    end
  end
end
