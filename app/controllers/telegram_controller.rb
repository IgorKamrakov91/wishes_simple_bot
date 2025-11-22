require "telegram/bot"

class TelegramController < ApplicationController

  def webhook
    Telegram::Bot::Client.run("8179126467:AAFWyk5lQ9cOZSAHvyaNGfBppR6udi2ohx8") do |bot|
      update = Telegram::Bot::Types::Update.new(JSON.parse(request.raw_post))
      Bot::Dispatcher.dispatch(bot, update)
    end

    head :ok
  end
end
