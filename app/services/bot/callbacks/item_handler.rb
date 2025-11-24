# frozen_string_literal: true

module Bot
  module Callbacks
    class ItemHandler < BaseHandler
      def add_item_prompt(wishlist_id)
        user.start_adding_item!(wishlist_id: wishlist_id)
        context.send_text("Введите название подарка:")
      end

      def edit_item_menu(item_id)
        item = Item.find(item_id)

        buttons = [
          [context.inline_btn("Название", "edit_item_field:title:#{item.id}")],
          [context.inline_btn("Описание", "edit_item_field:description:#{item.id}")],
          [context.inline_btn("URL", "edit_item_field:url:#{item.id}")],
          [context.inline_btn("Цена", "edit_item_field:price:#{item.id}")]
        ]

        context.send_text("Что хотите изменить для «#{item.title}»?", context.build_keyboard(buttons))
      end

      def edit_item_field_prompt(field, item_id)
        user.update!(
          bot_state: "editing_item",
          bot_payload: { item_id: item_id, field: field }
        )

        context.send_text("Введите новое значение поля «#{field}»:")
      end

      def toggle_reserve(item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist

        if item.reserved_by && item.reserved_by != user.telegram_id
          context.send_text("Этот подарок забронирован другим пользователем.")
          return
        end

        # Toggle reservation
        if item.reserved_by == user.telegram_id
          item.update!(reserved_by: nil)
          notify_viewers(wishlist, "🔓 Резерв снят с «#{item.title}»")
        else
          item.update!(reserved_by: user.telegram_id)
          notify_viewers(wishlist, "🔒 «#{item.title}» / #{item.wishlist.title}, забронирован пользователем @#{user.username}")
        end

        # Update the message with a new state
        item.reload
        presenter = Presenters::ItemPresenter.new(item, user, context)
        context.edit_message(presenter.text, presenter.keyboard)
      end

      def delete_item(item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist
        item_title = item.title

        item.destroy!

        notify_viewers(wishlist, "🗑 «#{item_title}» удален")

        keyboard = context.build_keyboard([ [ context.inline_btn("Открыть список", "open_list:#{wishlist.id}") ] ])
        context.send_text("Подарок удален!", keyboard)
      end
    end
  end
end
