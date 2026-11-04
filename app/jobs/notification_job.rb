require "telegram/bot"

# Sends one notification text (bot.notifications.<kind>) to one user,
# outside the button response
class NotificationJob < ApplicationJob
  queue_as :notifications
  self.log_arguments = false

  def perform(telegram_id, kind, details, locale)
    recipient = User.find_by(telegram_id: telegram_id)
    return unless recipient && still_wanted?(recipient, kind, details)

    text = I18n.with_locale(locale) { I18n.t("bot.notifications.#{kind}", **details.symbolize_keys) }
    bot = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))
    bot.api.send_message(chat_id: telegram_id, text: text)
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    code = e.error_code.to_i if e.is_a?(Telegram::Bot::Exceptions::ResponseError)
    if [ 400, 403, 404 ].include?(code)
      Rails.logger.info("Notification not delivered (Telegram #{code})")
      return
    end

    raise if executions >= 3

    retry_after = e.data.dig("parameters", "retry_after").to_i if code == 429
    retry_job(wait: retry_after&.positive? ? retry_after : 30)
  end

  private

  # The job may run later: respect a setting turned off meanwhile, and don't
  # tell a guest about a list they no longer have access to
  def still_wanted?(recipient, kind, details)
    case kind
    when /\Aown_/ then recipient.notify_own_reservations
    when /\Afriend_/
      recipient.notify_friend_reservations && Wishlist.accessible_to(recipient).exists?(details["wishlist_id"])
    else true
    end
  end
end
