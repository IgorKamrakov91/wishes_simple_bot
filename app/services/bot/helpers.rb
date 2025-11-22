module Bot
  module Helpers
    def send_text(bot, chat_id, text, reply_markup = nil)
      Rails.logger.info "SENDING TEXT: #{text}"
      Rails.logger.info "REPLY MARKUP: #{reply_markup}"
      Rails.logger.info "CHAT ID: #{chat_id}"
      
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