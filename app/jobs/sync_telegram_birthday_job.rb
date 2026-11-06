# frozen_string_literal: true

require "telegram/bot"

class SyncTelegramBirthdayJob < ApplicationJob
  queue_as :reminders
  self.log_arguments = false

  def perform(owner_id, checked_at = nil, attempt = 0)
    @owner = User.find_by(id: owner_id)
    return unless @owner

    if checked_at
      @checked_at = Time.iso8601(checked_at)
      return unless @owner.birthdate_checked_at == @checked_at && @owner.birthdate_synced_at.nil?
    else
      @checked_at = Time.current
      day_start = @checked_at.in_time_zone(ReminderSchedule::TIME_ZONE).beginning_of_day
      # Invalidate yesterday's cache before HTTP; a failed refresh must never
      # make an older birthdate eligible for a new notification.
      changed = User.where(id: owner_id).where("birthdate_checked_at IS NULL OR birthdate_checked_at < ?", day_start)
        .update_all(birthdate_checked_at: @checked_at, birthdate_synced_at: nil)
      return unless changed == 1
    end

    chat = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api.get_chat(chat_id: @owner.telegram_id)
    birthdate = chat.birthdate if chat.type == "private"
    valid = birthdate && Date.valid_date?(2000, birthdate.month, birthdate.day)
    updated = current_sync.update_all(birthdate_day: (birthdate.day if valid),
                                      birthdate_month: (birthdate.month if valid), birthdate_synced_at: Time.current)
    BirthdayReminders.dispatch_for(@owner.reload) if updated == 1
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    code = e.error_code.to_i if e.is_a?(Telegram::Bot::Exceptions::ResponseError)
    Rails.logger.info("Telegram birthday refresh failed (#{code || e.class})")
    return if [ 400, 403, 404 ].include?(code) || attempt >= 2

    retry_after = e.data.dig("parameters", "retry_after").to_i if code == 429
    wait = retry_after&.positive? ? retry_after : 30
    self.class.set(wait: wait.seconds).perform_later(@owner.id, @checked_at.utc.iso8601(6), attempt + 1)
  end

  private

  def current_sync
    User.where(id: @owner.id, birthdate_checked_at: @checked_at)
  end
end
