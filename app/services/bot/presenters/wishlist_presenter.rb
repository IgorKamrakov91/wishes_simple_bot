# frozen_string_literal: true

module Bot
  module Presenters
    class WishlistPresenter < BasePresenter
      PER_PAGE = 5
      TITLE_LIMIT = 32
      # Telegram colors inline buttons only by style (primary, success,
      # danger), not by any hex color
      MY_RESERVATION_STYLE = "success"
      TAKEN_STYLE = "danger"

      object_name :wishlist

      attr_reader :page

      def self.page_of(index)
        index / PER_PAGE
      end

      def initialize(wishlist, user, context, page: 0)
        super(wishlist, user, context)
        @page = page.clamp(0, total_pages - 1)
      end

      def text
        [ header, body ].join("\n\n")
      end

      def keyboard
        rows = page_items.map { |item| [ item_button(item) ] }
        rows << pager_row if total_pages > 1 && pager_row.any?

        if owner?
          rows << [ context.inline_btn(t("bot.buttons.add_item"), "add_item:#{wishlist.id}", style: "primary") ]
          rows << [ send_to_friend_button ]
          rows << [
            context.inline_btn(t("bot.buttons.share"), nil, copy_text: { text: share_link(wishlist) }),
            context.inline_btn(t("bot.buttons.list_settings"), "list_settings:#{wishlist.id}")
          ]
          rows << [ context.inline_btn(t("bot.buttons.back_to_lists"), ListCollectionPresenter.back_callback(wishlist, user, shared: false)) ]
        else
          # A guest without lists of their own is one tap away from making one
          rows << [ context.inline_btn(t("bot.buttons.create_own_list"), "new_list") ] unless user.wishlists.exists?
          rows << [ context.inline_btn(t("bot.buttons.back_to_shared_lists"), ListCollectionPresenter.back_callback(wishlist, user, shared: true)) ]
        end

        context.build_keyboard(rows)
      end

      private

      # Opens the chat picker; the chosen chat gets the list card from Inline
      def send_to_friend_button
        context.inline_btn(t("bot.buttons.send_to_friend"), nil,
                           switch_inline_query_chosen_chat: {
                             query: Inline.share_query(wishlist),
                             allow_user_chats: true,
                             allow_group_chats: true
                           })
      end

      def header
        lines = []
        lines << wishlist.owner_link unless owner?
        lines << "<b>#{escape_html(wishlist.title)}</b>"
        lines << summary_line if items.any?
        lines.join("\n")
      end

      # Plain words: a reservation is not a received gift, so no percentages
      def summary_line
        gifts = t("bot.inline.gifts", count: items.size)
        reserved = wishlist.reserved_items_count
        key = owner? ? "owner_summary" : "guest_summary"
        line = t("bot.screens.list.#{key}", gifts: gifts, reserved: reserved)
        line += " · #{t('bot.screens.list.page', page: page + 1, total: total_pages)}" if total_pages > 1
        line
      end

      def body
        if items.empty?
          owner? ? t("bot.screens.list.owner_empty") : t("bot.screens.list.guest_empty")
        else
          t("bot.screens.list.hint")
        end
      end

      # The guest's own reservations are green with a star, gifts taken by
      # someone else are red; the status word at the end keeps both readable
      # for screen readers and in clients that ignore button colors
      def item_button(item)
        options = if reserved_by_me?(item) then { style: MY_RESERVATION_STYLE }
        elsif item.reserved? then { style: TAKEN_STYLE }
        else {}
        end
        context.inline_btn(item_label(item), "open_item:#{item.id}", **options)
      end

      def item_label(item)
        label = +""
        label << "★ " if reserved_by_me?(item)
        label << item.title.to_s.truncate(TITLE_LIMIT)
        label << " · #{format_price(item.price)}" if item.price.present?
        label << " · #{item_status(item)}" if item.reserved?
        label
      end

      def item_status(item)
        reserved_by_me?(item) ? t("bot.screens.list.status_mine") : t("bot.screens.list.status_taken")
      end

      def reserved_by_me?(item)
        !owner? && item.reserved_by?(user)
      end

      # Only the steps that exist; the page number is in the text
      def pager_row
        @pager_row ||= [
          (context.inline_btn(t("bot.buttons.prev_page"), "list_page:#{wishlist.id}:#{page - 1}") if page.positive?),
          (context.inline_btn(t("bot.buttons.next_page"), "list_page:#{wishlist.id}:#{page + 1}") if page < total_pages - 1)
        ].compact
      end

      def items
        wishlist.items
      end

      def page_items
        items.to_a.slice(page * PER_PAGE, PER_PAGE) || []
      end

      def total_pages
        [ (items.size.to_f / PER_PAGE).ceil, 1 ].max
      end

      def owner?
        wishlist.user_id == user.id
      end
    end
  end
end
