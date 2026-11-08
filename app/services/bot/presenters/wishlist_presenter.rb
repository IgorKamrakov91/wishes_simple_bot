# frozen_string_literal: true

module Bot
  module Presenters
    class WishlistPresenter < BasePresenter
      PER_PAGE = 5
      TITLE_LIMIT = 32
      # Colors stay for actions: green is "Reserve", red is "Delete". The
      # guest's own reservations are blue, taken gifts have no color and a ✓
      MY_RESERVATION_STYLE = "primary"

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
        [ header, body ].compact.join("\n\n")
      end

      def keyboard
        rows = page_items.map { |item| [ item_button(item) ] }
        rows << pager_row if total_pages > 1 && pager_row.any?

        if owner?
          rows << [ context.inline_btn(t("bot.buttons.add_item"), "add_item:#{wishlist.id}", style: "primary") ]
          rows << [
            send_to_friend_button,
            context.inline_btn(t("bot.buttons.share"), nil, copy_text: { text: share_link(wishlist) })
          ]
          rows << [
            context.inline_btn(t("bot.buttons.back_to_lists"), ListCollectionPresenter.back_callback(wishlist, user, shared: false)),
            context.inline_btn(t("bot.buttons.list_settings"), "list_settings:#{wishlist.id}")
          ]
        else
          row = [ context.inline_btn(t("bot.buttons.back_to_shared_lists"), ListCollectionPresenter.back_callback(wishlist, user, shared: true)) ]
          # A guest without lists of their own is one tap away from making one
          row << context.inline_btn(t("bot.buttons.create_own_list"), "new_list") unless user.wishlists.exists?
          rows << row
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
        lines << t("bot.screens.list.shared_by", owner: wishlist.owner_link) unless owner?
        lines << "🎁 <b>#{escape_html(wishlist.title)}</b>"
        lines << progress_line if items.any?
        lines.join("\n")
      end

      # Dots count gifts, not money or percent: a reservation is not a
      # received gift
      def progress_line
        reserved = wishlist.reserved_items_count
        line = +"#{progress_dots(reserved, items.size)}  "
        line << t("bot.screens.list.progress", reserved: reserved, total: items.size)
        line << " · #{t('bot.screens.list.page', page: page + 1, total: total_pages)}" if total_pages > 1
        line
      end

      def body
        if items.empty?
          owner? ? t("bot.screens.list.owner_empty") : t("bot.screens.list.guest_empty")
        elsif !owner? && items.any?(&:reserved?)
          t("bot.screens.list.legend")
        end
      end

      # The ★ and ✓ marks carry the status in clients that ignore button colors
      def item_button(item)
        options = reserved_by_me?(item) ? { style: MY_RESERVATION_STYLE } : {}
        context.inline_btn(item_label(item), "open_item:#{item.id}", **options)
      end

      def item_label(item)
        label = +""
        if reserved_by_me?(item) then label << "★ "
        elsif item.reserved? then label << "✓ "
        end
        label << item.title.to_s.truncate(TITLE_LIMIT)
        label << " · #{format_price(item.price)}" if item.price.present?
        label
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
