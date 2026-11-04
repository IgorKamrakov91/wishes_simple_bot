# frozen_string_literal: true

require "cgi"

module Bot
  module Callbacks
    class WishlistHandler < BaseHandler
      def main_menu
        text = I18n.t("bot.screens.main.text",
                      name: escape_html(user.first_name.presence || user.full_name),
                      lists: user.wishlists.count,
                      items: Item.joins(:wishlist).where(wishlists: { user_id: user.id }).count,
                      shared: user.viewed_wishlists.distinct.count)

        keyboard = context.build_keyboard([
          [
            context.inline_btn(I18n.t("bot.buttons.my_lists"), "show_lists"),
            context.inline_btn(I18n.t("bot.buttons.shared_lists"), "show_shared_lists")
          ],
          [ context.inline_btn(I18n.t("bot.buttons.create_list"), "new_list", style: "primary") ]
        ])

        context.render(text, keyboard)
      end

      def show_lists
        lists = user.wishlists.includes(:items).order(:id)

        summaries = lists.map do |list|
          "<b>#{escape_html(list.title)}</b>\n#{list_progress(list, :my_lists)}"
        end
        text = [
          "<b>#{I18n.t('bot.buttons.my_lists')}</b>",
          summaries.presence&.join("\n\n") || I18n.t("bot.screens.my_lists.empty")
        ].join("\n\n")

        buttons = lists.map do |list|
          [ context.inline_btn("#{list.title.truncate(40)} · #{list.items.size}", "open_list:#{list.id}") ]
        end
        buttons << [ context.inline_btn(I18n.t("bot.buttons.create_list"), "new_list", style: "primary") ]
        buttons << [ context.inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]

        context.render(text, context.build_keyboard(buttons))
      end

      def show_shared_lists
        lists = user.viewed_wishlists.includes(:user, :items).distinct.order(:id)

        summaries = lists.map do |list|
          "#{list.owner_link} · <b>#{escape_html(list.title)}</b>\n#{list_progress(list, :shared_lists)}"
        end
        text = [
          "<b>#{I18n.t('bot.buttons.shared_lists')}</b>",
          summaries.presence&.join("\n\n") || I18n.t("bot.screens.shared_lists.empty")
        ].join("\n\n")

        buttons = lists.map do |list|
          owner_name = list.owner.first_name.presence || list.owner.full_name
          [ context.inline_btn("#{owner_name} · #{list.title}".truncate(48), "open_list:#{list.id}") ]
        end
        buttons << [ context.inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]

        context.render(text, context.build_keyboard(buttons))
      end

      def create_list_prompt
        user.start_creating_list!
        context.render(I18n.t("bot.messages.enter_list_name"), cancel_keyboard("show_lists"))
      end

      def rename_list_prompt(wishlist_id)
        user.wishlists.find(wishlist_id)
        user.start_renaming_list!(wishlist_id: wishlist_id)
        context.render(I18n.t("bot.messages.enter_new_list_name"), cancel_keyboard("list_settings:#{wishlist_id}"))
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

        context.notice = I18n.t("bot.messages.list_deleted")
        show_lists
      end

      def open_list(wishlist_id, page = 0)
        wishlist = Wishlist.includes(:items, :user).find(wishlist_id)
        is_owner = wishlist.user_id == user.id

        add_user_to_list_viewers(user, wishlist) unless is_owner

        presenter = Presenters::WishlistPresenter.new(wishlist, user, context, page: page)
        context.render(presenter.text, presenter.keyboard)
      end

      def open_shared_list(wishlist_id)
        open_list(wishlist_id)
      end

      private

      def list_progress(list, screen)
        return I18n.t("bot.screens.#{screen}.no_items") if list.items.empty?

        stats = I18n.t("bot.screens.#{screen}.progress", reserved: list.reserved_items_count, total: list.items.size)
        mine = list.items.count { |item| item.reserved_by == user.telegram_id }
        stats += I18n.t("bot.screens.shared_lists.mine", number: mine) if screen == :shared_lists && mine.positive?

        "#{progress_bar_string(list.percentage_fulfilled)} #{stats}"
      end

      def add_user_to_list_viewers(user, wishlist)
        return if wishlist.has_viewer?(user)

        wishlist.list_viewers.create!(user: user)
      end
    end
  end
end
