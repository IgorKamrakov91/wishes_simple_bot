# frozen_string_literal: true

module Bot
  module Callbacks
    class ItemHandler < BaseHandler
      def add_item_prompt(wishlist_id)
        user.start_adding_item!(wishlist_id: wishlist_id)
        context.send_text(I18n.t("bot.messages.enter_item_name"))
      end

      def edit_item_menu(item_id)
        item = Item.find(item_id)

        buttons = [
          [ context.inline_btn(I18n.t("bot.buttons.title"), "edit_item_field:title:#{item.id}") ],
          [ context.inline_btn(I18n.t("bot.buttons.description"), "edit_item_field:description:#{item.id}") ],
          [ context.inline_btn(I18n.t("bot.buttons.url"), "edit_item_field:url:#{item.id}") ],
          [ context.inline_btn(I18n.t("bot.buttons.price"), "edit_item_field:price:#{item.id}") ]
        ]

        context.send_text(I18n.t("bot.messages.what_to_edit", title: item.title), context.build_keyboard(buttons))
      end

      def edit_item_field_prompt(field, item_id)
        user.update!(
          bot_state: "editing_item",
          bot_payload: { item_id: item_id, field: field }
        )

        context.send_text(I18n.t("bot.messages.enter_new_value", field: field))
      end

      def toggle_reserve(item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist

        if item.reserved_by && item.reserved_by != user.telegram_id
          context.send_text(I18n.t("bot.messages.already_reserved"))
          return
        end

        # Toggle reservation
        if item.reserved_by == user.telegram_id
          item.update!(reserved_by: nil)
          notify_viewers(wishlist, I18n.t("bot.messages.reserve_lifted", title: item.title, list_title: wishlist.title, list_owner: wishlist.owner.full_name))
        else
          item.update!(reserved_by: user.telegram_id)
          notify_viewers(wishlist, I18n.t("bot.messages.reserved_by", title: item.title, list_title: wishlist.title, user: "@#{user.username}"))
        end

        # Update the message with a new state
        item.reload
        presenter = Presenters::ItemPresenter.new(item, user, context)
        context.edit_message(presenter.text, presenter.keyboard, parse_mode: "HTML")
      end

      def delete_item(item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist
        item_title = item.title

        item.destroy!

        notify_viewers(wishlist, I18n.t("bot.messages.item_deleted", title: item_title))

        keyboard = context.build_keyboard([ [ context.inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{wishlist.id}") ] ])
        context.send_text(I18n.t("bot.messages.item_deleted_success"), keyboard)
      end
    end
  end
end
