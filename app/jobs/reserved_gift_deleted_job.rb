require "telegram/bot"

class ReservedGiftDeletedJob < ApplicationJob
  queue_as :notifications
  self.log_arguments = false

  def perform(telegram_id, kind, details, locale)
    return unless User.exists?(telegram_id: telegram_id)

    text = I18n.with_locale(locale) { I18n.t("bot.notifications.#{kind}", **details.symbolize_keys) }
    bot = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))
    bot.api.send_message(chat_id: telegram_id, text: text)
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    code = e.error_code.to_i if e.is_a?(Telegram::Bot::Exceptions::ResponseError)
    if [ 400, 403, 404 ].include?(code)
      Rails.logger.info("Reservation deletion notification not delivered (Telegram #{code})")
      return
    end

    raise if executions >= 3

    retry_after = e.data.dig("parameters", "retry_after").to_i if code == 429
    retry_job(wait: retry_after&.positive? ? retry_after : 30)
  end
end
