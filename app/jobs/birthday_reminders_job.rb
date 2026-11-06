# frozen_string_literal: true

class BirthdayRemindersJob < ApplicationJob
  queue_as :reminders

  def perform
    # Only owners whose lists have guests who want birthday reminders.
    owners = Wishlist.joins(:list_viewers).where(list_viewers: { user_id: User.where(notify_birthdays: true).select(:id) })
      .where("list_viewers.user_id <> wishlists.user_id").select(:user_id)
    User.where(id: owners).find_each.with_index do |owner, index|
      SyncTelegramBirthdayJob.set(wait: index.seconds).perform_later(owner.id)
    end
  end
end
