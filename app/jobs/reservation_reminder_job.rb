# frozen_string_literal: true

require "telegram/bot"

class ReservationReminderJob < ApplicationJob
  include Bot::Helpers

  queue_as :reminders
  self.log_arguments = false

  def perform(user_id, due_at, attempt = 0)
    @recipient = User.find_by(id: user_id)
    @due_at = Time.iso8601(due_at)
    @days = @recipient&.reservation_reminder_days
    return unless @recipient && [ 7, 14, 30 ].include?(@days) && @due_at <= Time.current

    opening = ReminderSchedule.next_send_at(Time.current)
    return reschedule(opening, attempt) if opening > Time.current
    return unless unpurchased.exists?

    # Claim this due time before the HTTP request, without holding a user row
    # lock during delivery. Concurrent jobs and restarts cannot claim it twice.
    @claimed_next_at = ReminderSchedule.after_days(Time.current, @days)
    return unless pending.update_all(reservation_reminder_next_at: @claimed_next_at,
                                     reservation_reminder_last_attempt_at: Time.current) == 1

    @recipient.reload
    return unless @recipient.reservation_reminder_days == @days

    gifts = unpurchased.includes(wishlist: :user).limit(5).to_a
    return if gifts.empty?

    text = reminder_text(gifts, unpurchased.count)
    keyboard = build_keyboard([
      [ inline_btn(I18n.t("bot.screens.reservations.title"), "show_reservations") ],
      [ inline_btn(I18n.t("bot.buttons.settings"), "settings") ]
    ])
    Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api.send_message(
      chat_id: @recipient.telegram_id, text: text, reply_markup: keyboard, link_preview_options: no_link_preview
    )

    sent_at = Time.current
    User.where(id: @recipient.id).update_all(reservation_reminder_last_sent_at: sent_at)
    claimed.update_all(reservation_reminder_next_at: ReminderSchedule.after_days(sent_at, @days))
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    code = e.error_code.to_i if e.is_a?(Telegram::Bot::Exceptions::ResponseError)
    Rails.logger.info("Reservation reminder delivery failed (#{code || e.class})")
    # A timeout can mean Telegram accepted the message. Leave the claimed
    # interval in place rather than sending the same reminder again.
    return if code.nil? || [ 400, 403, 404 ].include?(code) || attempt >= 2

    wait = code == 429 ? e.data.dig("parameters", "retry_after").to_i : 30
    reschedule(ReminderSchedule.next_send_at(Time.current + [ wait, 1 ].max.seconds), attempt + 1, scope: claimed)
  end

  private

  def unpurchased
    Bot::Presenters::ReservationsPresenter.scope_for(@recipient).where(purchased_at: nil).order(:id)
  end

  def pending
    User.where(id: @recipient.id, reservation_reminder_days: @days, reservation_reminder_next_at: @due_at)
  end

  def claimed
    User.where(id: @recipient.id, reservation_reminder_days: @days, reservation_reminder_next_at: @claimed_next_at)
  end

  def reschedule(time, attempt, scope: pending)
    return unless scope.update_all(reservation_reminder_next_at: time) == 1

    self.class.set(wait_until: time).perform_later(@recipient.id, time.utc.iso8601(6), attempt)
  end

  def reminder_text(gifts, total)
    lines = [ I18n.t("bot.reminders.reservations.heading"), I18n.t("bot.reminders.reservations.count", count: total), "" ]
    gifts.each { |item| lines << "• #{item.title.to_s.truncate(60)} — #{owner_name(item)}, «#{item.wishlist.title.to_s.truncate(40)}»" }
    lines << I18n.t("bot.reminders.reservations.more", count: total - gifts.size) if total > gifts.size
    lines << "\n#{I18n.t('bot.reminders.reservations.hint')}"
    lines.join("\n")
  end

  # Two friends can both have a "Birthday" list: the owner tells them apart
  def owner_name(item)
    owner = item.wishlist.owner
    (owner.first_name.presence || owner.full_name).to_s.truncate(30)
  end
end
