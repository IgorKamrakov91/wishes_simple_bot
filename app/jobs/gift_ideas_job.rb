require "telegram/bot"

# Gets ideas for one request and sends them as a separate message. The result
# is saved before delivery, so a failed delivery never asks the model again.
class GiftIdeasJob < ApplicationJob
  queue_as :default
  self.log_arguments = false
  # Requests from different people run in parallel, but at most two at a
  # time: the three shared worker threads always keep one for notifications
  # and reminders. The rest wait in the queue for a few seconds.
  limits_concurrency to: 2, key: "gift_ideas", duration: 2.minutes

  def perform(suggestion_id)
    suggestion = GiftSuggestion.find_by(id: suggestion_id)
    return unless suggestion&.claim!

    # Switched off after the request was queued: don't call the model, but
    # finish the request so it doesn't keep the owner waiting
    if GiftSuggestion.enabled?
      generate(suggestion)
    else
      suggestion.fail!("disabled")
    end
    deliver(suggestion)
  end

  private

  def generate(suggestion)
    wishlist = suggestion.wishlist
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    suggestion.finish!(YandexAi::GiftIdeas.new.call(wishlist.title, wishlist.items.pluck(:title)))
    log(suggestion, "ready", started)
  rescue YandexAi::Client::Error => e
    suggestion.fail!(e.code)
    log(suggestion, e.code, started)
  rescue StandardError => e
    suggestion.fail!("error")
    Rails.logger.error("Gift ideas #{suggestion.id} failed (#{e.class})")
  end

  def deliver(suggestion)
    I18n.with_locale(suggestion.locale) do
      presenter = Bot::Presenters::GiftIdeasPresenter.new(suggestion)
      bot = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))
      bot.api.send_message(chat_id: suggestion.user.telegram_id, text: presenter.text,
                           reply_markup: presenter.keyboard, parse_mode: "HTML")
    end
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    # The ideas stay saved; the owner can open them again from the list
    Rails.logger.info("Gift ideas #{suggestion.id} not delivered (#{e.class})")
  end

  def log(suggestion, result, started)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger.info("Gift ideas #{suggestion.id}: #{result} in #{ms} ms")
  end
end
