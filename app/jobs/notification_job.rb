require "telegram/bot"

# Sends one notification text (bot.notifications.<kind>) to one user,
# outside the button response
class NotificationJob < ApplicationJob
  include Bot::Helpers

  queue_as :notifications
  self.log_arguments = false

  def perform(telegram_id, kind, details, locale)
    recipient = User.find_by(telegram_id: telegram_id)
    return unless recipient && still_wanted?(recipient, kind, details)

    text = I18n.with_locale(locale) { I18n.t("bot.notifications.#{kind}", **details.symbolize_keys) }
    bot = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))
    keyboard = I18n.with_locale(locale) { actions(details) }
    bot.api.send_message(chat_id: telegram_id, text: text, reply_markup: keyboard)
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

  # The gift may be taken or deleted by the time the button is pressed: the
  # card shows its current state, and a deleted one answers as unavailable.
  # Jobs queued before item ids were added open the list instead.
  def actions(details)
    open = if details["item_id"]
      inline_btn(I18n.t("bot.buttons.open_item"), "open_item:#{details['item_id']}")
    else
      inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{details['wishlist_id']}")
    end
    build_keyboard([ [ open ], [ inline_btn(I18n.t("bot.buttons.settings"), "settings") ] ])
  end

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
