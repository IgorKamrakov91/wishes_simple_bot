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
        user.record_contact!(kind: "inline_query")
        query = inline_query.query.to_s.strip
        if (share = SHARE_QUERY.match(query)) && user.wishlists.exists?(id: share[1])
          user.record_first_funnel_event!(:first_share_query_at)
        end

        lists =
          if (match = SHARE_QUERY.match(query))
            # Only the owner can share: the query is typed by whoever uses it
            user.wishlists.where(id: match[1])
          elsif query.empty?
            user.wishlists
          else
            user.wishlists.where("title ILIKE ?", "%#{Wishlist.sanitize_sql_like(query)}%")
          end

        # Telegram requests the next page as the user scrolls. Fetch one extra
        # list so a full final page does not advertise an empty continuation.
        raw_offset = inline_query.offset.to_s
        offset = raw_offset.match?(/\A\d{1,9}\z/) ? raw_offset.to_i : 0
        page = lists.order(updated_at: :desc, id: :desc).offset(offset)
          .limit(RESULTS_LIMIT + 1).includes(:user).to_a
        next_offset = page.size > RESULTS_LIMIT ? (offset + RESULTS_LIMIT).to_s : ""
        visible_lists = page.first(RESULTS_LIMIT)
        # Cards only need counts; do not load every gift (and its description)
        # in these lists or in the extra list used to detect the next page.
        gift_counts = Item.where(wishlist_id: visible_lists.map(&:id)).group(:wishlist_id).count

        bot.api.answer_inline_query(
          inline_query_id: inline_query.id,
          results: visible_lists.map { |list| inline_result_for_list(list, gift_count: gift_counts.fetch(list.id, 0)) },
          next_offset: next_offset,
          cache_time: 0,
          is_personal: true
        )
      end

      def inline_result_for_list(list, gift_count: list.items.size)
        # Legacy lists predate title validation. Bound display values only so
        # one long name cannot prevent Telegram from returning any results.
        title = list.title.to_s.truncate(Wishlist::TITLE_LIMIT)
        owner = (list.owner.first_name.presence || list.owner.full_name).to_s.truncate(100)
        gifts = I18n.t("bot.inline.gifts", count: gift_count)

        Telegram::Bot::Types::InlineQueryResultArticle.new(
          id: list.id.to_s,
          title: title,
          description: gifts,
          input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(
            message_text: I18n.t("bot.inline.card", owner: owner, title: title, gifts: gifts)
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
