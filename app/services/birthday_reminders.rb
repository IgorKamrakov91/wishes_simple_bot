# frozen_string_literal: true

module BirthdayReminders
  module_function

  def upcoming(owner, today: Time.current.in_time_zone(ReminderSchedule::TIME_ZONE).to_date)
    return unless owner.birthdate_synced_at && owner.birthdate_checked_at
    return unless owner.birthdate_synced_at >= owner.birthdate_checked_at
    return unless owner.birthdate_synced_at.in_time_zone(ReminderSchedule::TIME_ZONE).to_date == today
    return unless owner.birthdate_day && owner.birthdate_month && Date.valid_date?(2000, owner.birthdate_month, owner.birthdate_day)

    date = date_in_year(owner, today.year)
    date = date_in_year(owner, today.year + 1) if date < today
    date if (1..30).cover?((date - today).to_i)
  end

  def date_in_year(owner, year)
    # A February 29 profile still gets a reminder in non-leap years. The
    # message keeps the profile's original date; no birth year is stored.
    day = [ owner.birthdate_day, Date.new(year, owner.birthdate_month, -1).day ].min
    Date.new(year, owner.birthdate_month, day)
  end

  def dispatch_for(owner)
    date = upcoming(owner)
    return unless date

    guest_ids = ListViewer.where(wishlist_id: owner.wishlists.select(:id)).select(:user_id)
    User.where(id: guest_ids, notify_birthdays: true).where.not(id: owner.id).find_each.with_index do |recipient, index|
      delivery = BirthdayReminderDelivery.create_or_find_by!(recipient: recipient, owner: owner, birthday_year: date.year)
      next unless BirthdayReminderDelivery.ready.exists?(delivery.id)

      BirthdayReminderJob.set(wait: index.seconds).perform_later(delivery.id)
    end
  rescue ActiveRecord::InvalidForeignKey
    # An account may have been deleted between selecting guests and enqueue.
    Rails.logger.info("Birthday reminder skipped for a deleted account")
  end
end
