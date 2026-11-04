module Bot
  module Helpers
    def send_text(bot, chat_id, text, reply_markup = nil, parse_mode: nil, link_preview_options: nil)
      Rails.logger.info "SENDING TEXT: #{text}"
      Rails.logger.info "REPLY MARKUP: #{reply_markup}"
      Rails.logger.info "CHAT ID: #{chat_id}"

      bot.api.send_message(**{
        chat_id: chat_id,
        text: text,
        reply_markup: reply_markup,
        parse_mode: parse_mode,
        link_preview_options: link_preview_options
      }.compact)
    end

    def inline_btn(text, data = nil, **options)
      # Handle copy_text option - convert hash to CopyTextButton object
      if options[:copy_text].is_a?(Hash)
        options[:copy_text] = Telegram::Bot::Types::CopyTextButton.new(options[:copy_text])
      end

      params = { text: text }
      params[:callback_data] = data if data
      params.merge!(options)

      Telegram::Bot::Types::InlineKeyboardButton.new(params)
    end

    def update_or_send(bot, callback, text, keyboard, parse_mode: nil)
      if callback.inline_message_id
        bot.api.edit_message_text(
          inline_message_id: callback.inline_message_id,
          text: text,
          reply_markup: keyboard,
          parse_mode: parse_mode
        )
      elsif callback.message
        bot.api.edit_message_text(
          chat_id: callback.message.chat.id,
          message_id: callback.message.message_id,
          text: text,
          reply_markup: keyboard,
          parse_mode: parse_mode
        )
      else
        # fallback
        bot.api.send_message(
          chat_id: callback.from.id,
          text: text,
          reply_markup: keyboard,
          parse_mode: parse_mode
        )
      end
    end

    def build_keyboard(buttons)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end

    def no_link_preview
      Telegram::Bot::Types::LinkPreviewOptions.new(is_disabled: true)
    end

    def progress_bar_string(percentage, length = 10)
      filled_blocks = (percentage.to_f.clamp(0, 100) / 100 * length).round
      "▰" * filled_blocks + "▱" * (length - filled_blocks)
    end

    def format_price(price)
      amount = ActiveSupport::NumberHelper.number_to_rounded(
        price,
        precision: 2,
        strip_insignificant_zeros: true,
        delimiter: I18n.t("bot.presenters.item.price_delimiter"),
        separator: I18n.t("bot.presenters.item.price_separator")
      )
      I18n.t("bot.presenters.item.price", amount: amount)
    end

    def escape_html(text)
      CGI.escapeHTML(text.to_s)
    end

    def bot_link
      bot_username = (ENV["BOT_USERNAME"].presence || "PodarkiNeOtdarkiBot").delete_prefix("@")

      "https://t.me/#{bot_username}"
    end

    def share_link(wishlist)
      "#{bot_link}?start=l_#{wishlist.share_token}"
    end
  end
end
