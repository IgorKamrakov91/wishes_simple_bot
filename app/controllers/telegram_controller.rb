require "telegram/bot"

class TelegramController < ApplicationController

  def webhook
    Telegram::Bot::Client.run(ENV["TELEGRAM_BOT_TOKEN"]) do |bot|
      update = Telegram::Bot::Types::Update.new(JSON.parse(request.raw_post))
      Bot::Dispatcher.dispatch(bot, update)
    end

    head :ok
  end
end
