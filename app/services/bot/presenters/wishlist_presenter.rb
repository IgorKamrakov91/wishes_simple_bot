# frozen_string_literal: true

module Bot
  module Presenters
    class WishlistPresenter < BasePresenter
      object_name :wishlist

      def management_keyboard
        context.build_keyboard(management_buttons)
      end

      private

      def management_buttons
        buttons = []

        if owner?
          buttons << [ context.inline_btn(I18n.t("bot.buttons.add_item"), "add_item:#{wishlist.id}") ]
          buttons << [ context.inline_btn(I18n.t("bot.buttons.rename_list"), "rename_list:#{wishlist.id}") ]
          buttons << [ context.inline_btn(I18n.t("bot.buttons.delete_list"), "delete_list:#{wishlist.id}") ]
        end

        buttons << [ context.inline_btn(I18n.t("bot.buttons.back_to_lists"), "show_lists") ]
        buttons
      end

      def owner?
        wishlist.user_id == user.id
      end
    end
  end
end
