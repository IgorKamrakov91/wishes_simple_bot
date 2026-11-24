# frozen_string_literal: true

module Bot
  module Presenters
    # What a newcomer sees after saving their first gift: the list is ready
    # to send, more gifts and a link are optional next steps.
    class FirstGiftPresenter
      include Helpers

      def initialize(item, context)
        @item = item
        @context = context
      end

      # [text, keyboard]
      def screen
        wishlist = @item.wishlist
        text = I18n.t("bot.messages.first_gift_saved",
                      title: escape_html(@item.title.to_s.truncate(Item::TITLE_LIMIT)),
                      list: escape_html(wishlist.title.to_s.truncate(Wishlist::TITLE_LIMIT)))
        rows = [ [ WishlistPresenter.send_to_friend_button(@context, wishlist) ] ]
        rows << [ @context.inline_btn(I18n.t("bot.buttons.guest_preview"), "guest_preview:#{wishlist.id}") ]
        rows << [ @context.inline_btn(I18n.t("bot.buttons.add_more"), "add_item:#{wishlist.id}", style: "primary") ]
        rows << [ @context.inline_btn(I18n.t("bot.buttons.add_link"), "edit_item_field:url:#{@item.id}") ] if @item.url.blank?
        rows << [ @context.inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{wishlist.id}") ]
        [ text, @context.build_keyboard(rows) ]
      end
    end
  end
end
