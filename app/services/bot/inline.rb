module Bot
  class Inline
    extend Bot::Helpers

    class << self
      def handle_query(bot, inline_query)
        user = User.find_or_create_from_telegram(inline_query.from.to_h.symbolize_keys)

        # Check if this is a share request (format: share_ID)
        if inline_query.query.match?(/^share_(\d+)$/)
          list_id = inline_query.query.match(/^share_(\d+)$/)[1].to_i
          list = user.wishlists.find_by(id: list_id)

          results = list ? [ inline_result_for_list(list, shared: true) ] : []
        else
          # Regular search by title
          query = inline_query.query.to_s.strip
          lists = query.empty? ? user.wishlists : user.wishlists.where("title LIKE ?", "%#{query}%")
          results = lists.map { |list| inline_result_for_list(list) }
        end

        bot.api.answer_inline_query(
          inline_query_id: inline_query.id,
          results: results,
          cache_time: 0
        )
      end

      def inline_result_for_list(list, shared: false)
        message_text = shared ? "🎁 Вишлист: #{list.title}" : "Открыть вишлист: #{list.title}"

        Telegram::Bot::Types::InlineQueryResultArticle.new(
          id: list.id.to_s,
          title: list.title,
          description: "#{list.items.count} подарков",
          input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(
            message_text: message_text
          ),
          reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "Открыть вишлист",
                  callback_data: "open_shared_list:#{list.id}")
              ]
            ]
          )
        )
      end
    end
  end
end
