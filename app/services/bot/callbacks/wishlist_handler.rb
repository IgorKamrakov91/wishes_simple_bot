# frozen_string_literal: true

require "cgi"

module Bot
  module Callbacks
    class WishlistHandler < BaseHandler
      def main_menu
        name = escape_html(user.first_name.presence || user.full_name)
        lists = user.wishlists.count
        shared = user.viewed_wishlists.distinct.count

        # A newcomer gets how it works and one next step instead of zero counters
        if lists.zero? && shared.zero?
          keyboard = context.build_keyboard([
            [ context.inline_btn(I18n.t("bot.buttons.create_first_list"), "new_list", style: "primary") ]
          ])
          return context.render(I18n.t("bot.screens.main.welcome", name: name), keyboard)
        end

        lines = [ I18n.t("bot.screens.main.greeting", name: name) ]
        if lists.positive?
          items = Item.joins(:wishlist).where(wishlists: { user_id: user.id }).count
          lines << I18n.t("bot.screens.main.own", lists: lists, items: items)
        end
        lines << I18n.t("bot.screens.main.shared", shared: shared) if shared.positive?
        lines << I18n.t("bot.screens.main.own_hint") if lists.zero?

        keyboard = context.build_keyboard([
          [
            context.inline_btn(I18n.t("bot.buttons.my_lists"), "show_lists"),
            context.inline_btn(I18n.t("bot.buttons.shared_lists"), "show_shared_lists")
          ],
          [ context.inline_btn(I18n.t("bot.screens.reservations.title"), "show_reservations") ],
          [ context.inline_btn(I18n.t("bot.buttons.create_list"), "new_list", style: "primary") ],
          [
            context.inline_btn(I18n.t("bot.buttons.settings"), "settings"),
            context.inline_btn(I18n.t("bot.buttons.help"), "help")
          ]
        ])

        context.render(lines.join("\n\n"), keyboard)
      end

      def show_lists(page = 0)
        presenter = Presenters::ListCollectionPresenter.new(user, context, page: page)
        context.render(presenter.text, presenter.keyboard)
      end

      def show_shared_lists(page = 0)
        presenter = Presenters::ListCollectionPresenter.new(user, context, shared: true, page: page)
        context.render(presenter.text, presenter.keyboard)
      end

      def create_list_prompt
        user.start_creating_list!
        InputPrompt.new(context).render
      end

      def rename_list_prompt(wishlist_id)
        user.wishlists.find(wishlist_id)
        user.start_renaming_list!(wishlist_id: wishlist_id)
        InputPrompt.new(context).render
      end

      def list_settings(wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)

        keyboard = context.build_keyboard([
          [ context.inline_btn(I18n.t("bot.buttons.rename_list"), "rename_list:#{wishlist.id}") ],
          [ context.inline_btn(I18n.t("bot.buttons.delete_list"), "confirm_delete_list:#{wishlist.id}", style: "danger") ],
          [ context.inline_btn(I18n.t("bot.buttons.back_to_list"), "open_list:#{wishlist.id}") ]
        ])

        context.render(I18n.t("bot.screens.list_settings.text", title: escape_html(wishlist.title)), keyboard)
      end

      def confirm_delete_list(wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)

        keyboard = context.build_keyboard([
          [
            context.inline_btn(I18n.t("bot.buttons.confirm_delete"), "delete_list:#{wishlist.id}", style: "danger"),
            context.inline_btn(I18n.t("bot.buttons.cancel"), "list_settings:#{wishlist.id}")
          ]
        ])

        context.render(I18n.t("bot.screens.list_settings.confirm_delete", title: escape_html(wishlist.title)), keyboard)
      end

      def delete_list(wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)
        wishlist.destroy!
        UpdateDelivery.record_result("list_deleted", wishlist.id)

        context.notice = I18n.t("bot.messages.list_deleted")
        show_lists
      end

      def open_list(wishlist_id, page = 0)
        wishlist = Wishlist.accessible_to(user).includes(:items, :user).find(wishlist_id)
        UpdateDelivery.record_view("list_view", wishlist.id)

        presenter = Presenters::WishlistPresenter.new(wishlist, user, context, page: page)
        context.render(presenter.text, presenter.keyboard)
      end

      def open_shared_list(wishlist_id)
        open_list(wishlist_id)
      end
    end
  end
end
