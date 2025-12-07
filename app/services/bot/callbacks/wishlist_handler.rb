# frozen_string_literal: true

module Bot
  module Callbacks
    class WishlistHandler < BaseHandler
      def show_lists
        lists = user.wishlists

        if lists.empty?
          context.send_text(
            I18n.t("bot.messages.no_lists"),
            context.build_keyboard([ [ context.inline_btn(I18n.t("bot.buttons.create_list"), "new_list") ] ])
          )
          return
        end

        buttons = lists.map do |list|
          [
            context.inline_btn(list.title, "open_list:#{list.id}"),
            context.inline_btn(I18n.t("bot.buttons.share"), nil, switch_inline_query: "share_#{list.id}")
          ]
        end
        buttons << [ context.inline_btn(I18n.t("bot.buttons.create_list"), "new_list") ]
        context.send_text(I18n.t("bot.buttons.my_lists"), context.build_keyboard(buttons))
      end

      def create_list_prompt
        user.start_creating_list!
        context.send_text(I18n.t("bot.messages.enter_list_name"))
      end

      def rename_list_prompt(wishlist_id)
        user.start_renaming_list!(wishlist_id: wishlist_id)
        context.send_text(I18n.t("bot.messages.enter_new_list_name"))
      end

      def delete_list(wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)
        wishlist.destroy!

        context.send_text(I18n.t("bot.messages.list_deleted"))
        show_lists
      end

      def open_list(wishlist_id)
        wishlist = Wishlist.find(wishlist_id)
        is_owner = wishlist.user_id == user.id

        add_user_to_list_viewers(user, wishlist) unless is_owner

        percentage = wishlist.percentage_fulfilled
        progress_bar = progress_bar_string(percentage)

        # Send header with a progress bar
        context.send_text(I18n.t("bot.messages.list_header", owner: wishlist.owner_link, title: wishlist.title, progress_bar: progress_bar, percentage: percentage), parse_mode: "HTML")

        # Send each item with its buttons
        if wishlist.items.empty?
          context.send_text(I18n.t("bot.messages.empty_list"))
        else
          wishlist.items.each do |item|
            presenter = Presenters::ItemPresenter.new(item, user, context)
            context.send_text(presenter.text, presenter.keyboard, parse_mode: "HTML")
          end
        end

        # Send list management buttons
        presenter = Presenters::WishlistPresenter.new(wishlist, user, context)
        context.send_text(I18n.t("bot.presenters.wishlist.management"), presenter.management_keyboard)
      end

      def open_shared_list(wishlist_id)
        open_list(wishlist_id)
      end

      private

      def add_user_to_list_viewers(user, wishlist)
        return if wishlist.has_viewer?(user)

        wishlist.list_viewers.create!(user: user)
      end
    end
  end
end
