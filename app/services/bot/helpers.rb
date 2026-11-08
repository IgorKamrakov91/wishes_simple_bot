module Bot
  module Helpers
    def send_text(bot, chat_id, text, reply_markup = nil, parse_mode: nil, link_preview_options: nil)
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
      if options[:switch_inline_query_chosen_chat].is_a?(Hash)
        options[:switch_inline_query_chosen_chat] =
          Telegram::Bot::Types::SwitchInlineQueryChosenChat.new(options[:switch_inline_query_chosen_chat])
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

    # One dot per gift, "●●○○" for 2 of 4. Longer lists are scaled to
    # `limit` dots, keeping "none" and "all" exact.
    def progress_dots(reserved, total, limit = 10)
      return "" unless total.positive?

      reserved = reserved.clamp(0, total)
      length = [ total, limit ].min
      filled = (reserved.to_f / total * length).round
      filled = filled.clamp(1, length - 1) if reserved.positive? && reserved < total
      "●" * filled + "○" * (length - filled)
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
