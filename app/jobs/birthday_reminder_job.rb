# frozen_string_literal: true

require "telegram/bot"

class BirthdayReminderJob < ApplicationJob
  include Bot::Helpers

  queue_as :reminders
  self.log_arguments = false

  def perform(delivery_id)
    @delivery = BirthdayReminderDelivery.find_by(id: delivery_id)
    return unless @delivery && BirthdayReminderDelivery.ready.exists?(delivery_id)

    recipient = @delivery.recipient
    owner = @delivery.owner
    date = BirthdayReminders.upcoming(owner)
    return unless recipient.notify_birthdays && date&.year == @delivery.birthday_year && recipient != owner

    lists, any_free = lists_for(owner, recipient)
    return if lists.empty?

    opening = ReminderSchedule.next_send_at(Time.current)
    return postpone(opening) if opening > Time.current

    # The unique recipient/owner/occurrence row survives queue retries and
    # multiple shared lists. Claim before HTTP without holding user locks.
    return unless BirthdayReminderDelivery.ready.where(id: delivery_id)
      .update_all([ "claimed_at = ?, attempts = attempts + 1", Time.current ]) == 1

    profile_date = Date.new(2000, owner.birthdate_month, owner.birthdate_day).strftime("%d.%m")
    text = I18n.t(any_free ? "bot.reminders.birthdays.text" : "bot.reminders.birthdays.text_nothing_free",
                  name: owner.full_name.to_s.truncate(100), date: profile_date)
    rows = lists.map { |list| [ inline_btn(list.title.to_s.truncate(50), "open_list:#{list.id}") ] }
    rows << [ inline_btn(I18n.t("bot.buttons.shared_lists"), "show_shared_lists") ]
    rows << [ inline_btn(I18n.t("bot.buttons.settings"), "settings") ]
    Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api.send_message(
      chat_id: recipient.telegram_id, text: text, reply_markup: build_keyboard(rows), link_preview_options: no_link_preview
    )
    @delivery.update!(sent_at: Time.current)
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    code = e.error_code.to_i if e.is_a?(Telegram::Bot::Exceptions::ResponseError)
    Rails.logger.info("Birthday reminder delivery failed (#{code || e.class})")
    return if code.nil? || [ 400, 403, 404 ].include?(code) || @delivery.reload.attempts >= 3

    retry_after = e.data.dig("parameters", "retry_after").to_i if code == 429
    wait = retry_after&.positive? ? retry_after : 30
    retry_at = ReminderSchedule.next_send_at(Time.current + wait.seconds)
    # Clear the claim and set the retry deadline together; another queued
    # copy must never observe an immediately eligible, unclaimed delivery.
    @delivery.update!(claimed_at: nil, retry_at: retry_at)
    self.class.set(wait_until: retry_at).perform_later(@delivery.id)
  rescue ActiveRecord::RecordNotFound
    # A recipient or owner can be deleted while this job is queued.
    nil
  end

  private

  # Up to three of the owner's lists the recipient can open: lists with free
  # gifts first, then other non-empty ones, then empty ones
  def lists_for(owner, recipient)
    free = Item.where(reserved_by: nil).where("items.wishlist_id = wishlists.id").select("1").arel.exists
    any = Item.where("items.wishlist_id = wishlists.id").select("1").arel.exists
    scope = owner.wishlists.where(id: Wishlist.accessible_to(recipient).select(:id))
    order = Arel.sql("CASE WHEN #{free.to_sql} THEN 0 WHEN #{any.to_sql} THEN 1 ELSE 2 END, wishlists.id")
    [ scope.order(order).limit(3).to_a, scope.where(free).exists? ]
  end

  def postpone(time)
    return unless BirthdayReminderDelivery.ready.where(id: @delivery.id).update_all(retry_at: time) == 1

    self.class.set(wait_until: time).perform_later(@delivery.id)
  end
end
