# frozen_string_literal: true

module Bot
  module Presenters
    class WishlistPresenter < BasePresenter
      PER_PAGE = 5
      TITLE_LIMIT = 32

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
        rows = page_items.map { |item| [ context.inline_btn(item_label(item), "open_item:#{item.id}") ] }
        rows << pager_row if total_pages > 1

        if owner?
          rows << [ context.inline_btn(t("bot.buttons.add_item"), "add_item:#{wishlist.id}", style: "primary") ]
          rows << [
            context.inline_btn(t("bot.buttons.share"), nil, copy_text: { text: share_link(wishlist) }),
            context.inline_btn(t("bot.buttons.list_settings"), "list_settings:#{wishlist.id}")
          ]
          rows << [ context.inline_btn(t("bot.buttons.back_to_lists"), "show_lists") ]
        else
          rows << [ context.inline_btn(t("bot.buttons.back_to_shared_lists"), "show_shared_lists") ]
        end

        context.build_keyboard(rows)
      end

      private

      def header
        lines = []
        lines << wishlist.owner_link unless owner?
        lines << "<b>#{escape_html(wishlist.title)}</b>"
        lines << progress_line if items.any?
        lines.join("\n")
      end

      def progress_line
        reserved = wishlist.reserved_items_count
        bar = progress_bar_string(wishlist.percentage_fulfilled)

        if owner?
          "#{bar} <b>#{wishlist.percentage_fulfilled}%</b>\n" +
            t("bot.screens.list.owner_progress", reserved: reserved, total: items.size)
        else
          "#{bar} " + t("bot.screens.list.guest_progress", reserved: reserved, total: items.size)
        end
      end

      def body
        if items.empty?
          owner? ? t("bot.screens.list.owner_empty") : t("bot.screens.list.guest_empty")
        elsif owner?
          t("bot.screens.list.hint")
        else
          "#{t('bot.screens.list.legend')}\n#{t('bot.screens.list.hint')}"
        end
      end

      def item_label(item)
        label = +"#{item_marker(item)}#{item.title.to_s.truncate(TITLE_LIMIT)}"
        label << " · #{format_price(item.price)}" if item.price.present?
        label
      end

      def item_marker(item)
        return "" unless item.reserved?
        return "★ " if !owner? && item.reserved_by?(user)

        "✓ "
      end

      def pager_row
        [
          page.positive? ? context.inline_btn("‹", "list_page:#{wishlist.id}:#{page - 1}") : context.inline_btn("·", "noop"),
          context.inline_btn("#{page + 1} / #{total_pages}", "noop"),
          page < total_pages - 1 ? context.inline_btn("›", "list_page:#{wishlist.id}:#{page + 1}") : context.inline_btn("·", "noop")
        ]
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
