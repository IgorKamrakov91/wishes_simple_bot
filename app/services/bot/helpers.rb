module Bot
  module Helpers
    def send_text(bot, chat_id, text, reply_markup = nil)
      bot.api.send_message(
        chat_id: chat_id,
        text: text,
        reply_markup: reply_markup
      )
    end

    def inline_btn(text, data)
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: text,
        callback_data: data
      )
    end
  end
end