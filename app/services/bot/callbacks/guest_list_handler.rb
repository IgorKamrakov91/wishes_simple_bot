module Bot
  module Callbacks
    class GuestListHandler < BaseHandler
      def open(wishlist_id, page, budget)
        WishlistHandler.new(context).open_list(wishlist_id, page, budget)
      end

      def filter_menu(wishlist_id, page, budget)
        wishlist = Wishlist.accessible_to(user).find(wishlist_id)
        return open(wishlist_id, page, "a") if wishlist.user_id == user.id

        UpdateDelivery.record_view("list_view", wishlist.id)
        selection = GuestList.new(wishlist, budget: budget)
        rows = GuestList::BUDGETS.each_slice(2).map do |keys|
          keys.map do |key|
            label = I18n.t("bot.guest_budget.options.#{key}")
            label = "✓ #{label}" if key == selection.budget
            inline_btn(label, "gl:#{wishlist.id}:0:#{key}")
          end
        end
        rows << [ inline_btn(I18n.t("bot.buttons.back"), selection.page_callback(page)) ]
        context.render(I18n.t("bot.guest_budget.menu"), context.build_keyboard(rows))
      end

      def show_item(item_id, budget)
        with_budget(budget) { ItemHandler.new(context).show_item(item_id) }
      end

      def reserve(item_id, version, budget)
        with_budget(budget) { ItemHandler.new(context).reserve_item(item_id, version) }
      end

      def release(item_id, version, budget)
        with_budget(budget) { ItemHandler.new(context).unreserve_item(item_id, version) }
      end

      def confirm_release(item_id, version, budget)
        with_budget(budget) { ItemHandler.new(context).confirm_release(item_id, version) }
      end

      def mark_purchased(item_id, version, value, budget)
        with_budget(budget) { ItemHandler.new(context).mark_purchased(item_id, version, value) }
      end

      private

      def with_budget(budget)
        context.guest_budget = GuestList.normalize(budget)
        yield
      end
    end
  end
end
