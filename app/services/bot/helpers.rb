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

    def inline_btn(text, data = nil, **options)
      params = { text: text }
      params[:callback_data] = data if data
      params.merge!(options)

      Telegram::Bot::Types::InlineKeyboardButton.new(params)
    end

    def update_or_send(bot, callback, text, keyboard)
      if callback.inline_message_id
        bot.api.edit_message_text(
          inline_message_id: callback.inline_message_id,
          text: text,
          reply_markup: keyboard,
          parse_mode: "Markdown"
        )
      elsif callback.message
        bot.api.edit_message_text(
          chat_id: callback.message.chat.id,
          message_id: callback.message.message_id,
          text: text,
          reply_markup: keyboard,
          parse_mode: "Markdown"
        )
      else
        # fallback
        bot.api.send_message(
          chat_id: callback.from.id,
          text: text,
          reply_markup: keyboard,
          parse_mode: "Markdown"
        )
      end
    end
  end
end
