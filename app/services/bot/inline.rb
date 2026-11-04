module Bot
  # Inline mode: "@bot share_<id>" from the "Send to a friend" button, or
  # "@bot <words>" to find one of your lists. The result is a public card
  # with the list's share link, so it is safe in any chat.
  class Inline
    extend Bot::Helpers

    SHARE_QUERY = /\Ashare_(\d+)\z/
    RESULTS_LIMIT = 20

    class << self
      def share_query(wishlist)
        "share_#{wishlist.id}"
      end

      def handle_query(bot, inline_query)
        user = User.find_or_create_from_telegram(inline_query.from.to_h.symbolize_keys)
        query = inline_query.query.to_s.strip

        lists =
          if (match = SHARE_QUERY.match(query))
            # Only the owner can share: the query is typed by whoever uses it
            user.wishlists.where(id: match[1])
          elsif query.empty?
            user.wishlists.order(updated_at: :desc)
          else
            user.wishlists.where("title ILIKE ?", "%#{Wishlist.sanitize_sql_like(query)}%").order(updated_at: :desc)
          end

        bot.api.answer_inline_query(
          inline_query_id: inline_query.id,
          results: lists.includes(:user, :items).limit(RESULTS_LIMIT).map { |list| inline_result_for_list(list) },
          cache_time: 0,
          is_personal: true
        )
      end

      def inline_result_for_list(list)
        gifts = I18n.t("bot.inline.gifts", count: list.items.size)

        Telegram::Bot::Types::InlineQueryResultArticle.new(
          id: list.id.to_s,
          title: list.title,
          description: gifts,
          input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(
            message_text: I18n.t("bot.inline.card", owner: list.owner.first_name.presence || list.owner.full_name,
                                                    title: list.title, gifts: gifts)
          ),
          reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [ [ Telegram::Bot::Types::InlineKeyboardButton.new(
              text: I18n.t("bot.inline.open"), url: share_link(list)
            ) ] ]
          )
        )
      end
    end
  end
end
