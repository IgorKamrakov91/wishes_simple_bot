module Bot
  class Inline
    extend Bot::Helpers

    class << self
      def handle_query(bot, inline_query)
        user = User.find_or_create_from_telegram(inline_query.from.to_h.symbolize_keys)

        lists = user.wishlists.where("title LIKE ?", "%#{inline_query.query}%")
        results = lists.map { |list| build_result(list) }

        bot.api.answer_inline_query(
          inline_query_id: inline_query.id,
          results: results,
          cache_time: 0
        )
      end

      def build_result(list)
        Telegram::Bot::Types::InlineQueryResultArticle.new(
          id: list.id.to_s,
          title: list.title,
          description: "#{list.items.count} подарков",
          input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(
            message_text: "Открыть вишлист: #{list.title}"
          ),
          reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "Открыть",
                  callback_data: "open_list:#{list.id}")
              ]
            ]
          )
        )
      end

      def handle_chosen(bot, chosen)
        # INFO: can be used for analytics
      end
    end
  end
end