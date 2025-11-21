class TelegramController < ApplicationController
  skip_before_action :verify_authenticity_token

  def webhook
    Telegram::Bot::Client.wrap(ENV["TELEGRAM_BOT_TOKEN"]) do |bot|
      update = Telegram::Bot::Types::Update.new(
        JSON.parse(request.raw_post)
      )

      Bot::Dispatcher.dispatch(bot, update)
    end

    head :ok
  end
end
