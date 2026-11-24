# frozen_string_literal: true

module Bot
  module Presenters
    # The owner's own list as a friend sees it before sending it. Gift
    # buttons only explain themselves, so the preview can't reserve or edit.
    class GuestPreviewPresenter < WishlistPresenter
      def text
        [ t("bot.screens.guest_preview.intro"), super ].join("\n\n")
      end

      def keyboard
        rows = page_items.map { |item| [ context.inline_btn(item_label(item), "preview_tap") ] }
        rows << preview_pager_row if total_pages > 1 && preview_pager_row.any?
        rows << [ send_to_friend_button ]
        rows << [ context.inline_btn(t("bot.buttons.back_to_list"), "open_list:#{wishlist.id}") ]
        context.build_keyboard(rows)
      end

      private

      # Everything on screen is the guest's view
      def owner?
        false
      end

      def reserved_by_me?(_item)
        false
      end

      def preview_pager_row
        @preview_pager_row ||= [
          (context.inline_btn(t("bot.buttons.prev_page"), "guest_preview:#{wishlist.id}:#{page - 1}") if page.positive?),
          (context.inline_btn(t("bot.buttons.next_page"), "guest_preview:#{wishlist.id}:#{page + 1}") if page < total_pages - 1)
        ].compact
      end
    end
  end
end
