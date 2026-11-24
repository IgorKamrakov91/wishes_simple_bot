module Bot
  module Presenters
    # A photo gift saved on its own because the person had picked a list.
    # The model may have misread the price, so fixing or undoing is one tap.
    class PhotoGiftAddedPresenter < BasePresenter
      object_name :draft

      def text
        item = draft.item
        price = " ≈ #{format_price(item.price)}" if item.price
        t("bot.photo_gift.added", title: escape_html(item.title), price: price,
                                  list: escape_html(item.wishlist.title))
      end

      def keyboard
        context.build_keyboard([ [
          context.inline_btn(t("bot.photo_gift.fix"), "open_item:#{draft.item_id}"),
          context.inline_btn(t("bot.photo_gift.undo"), "pgu:#{draft.id}")
        ] ])
      end
    end
  end
end
