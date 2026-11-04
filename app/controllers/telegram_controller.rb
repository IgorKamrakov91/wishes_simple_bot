require "telegram/bot"

class TelegramController < ApplicationController
  before_action :verify_telegram_secret

  def webhook
    Telegram::Bot::Client.run(ENV["TELEGRAM_BOT_TOKEN"]) do |bot|
      update = Telegram::Bot::Types::Update.new(JSON.parse(request.raw_post))
      Bot::Dispatcher.dispatch(bot, update)
    end

    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def verify_telegram_secret
    head :unauthorized unless Bot::Webhook.authentic?(request)
  end
end
