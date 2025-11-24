# frozen_string_literal: true

module Bot
  module Presenters
    class ItemPresenter < BasePresenter
      object_name :item

      def text
        icon = item.reserved_by ? "🔒" : "🎁"
        text = +"#{icon} #{item.title}\n"

        if item.reserved_by
          reserved_by_user = User.find_by(telegram_id: item.reserved_by)
          text << "🤵 @#{reserved_by_user&.username || reserved_by_user&.first_name}\n"
        end

        text << "💬 #{item.description}\n" if item.description.present?
        text << "🔗 #{item.url}\n" if item.url.present?
        text << "💵 #{item.price}₽\n" if item.price.present?

        text
      end

      def keyboard
        context.build_keyboard(buttons)
      end

      private

      def buttons
        buttons = []
        row = []

        # Reserve / unreserve button
        if item.reserved_by.nil?
          row << context.inline_btn("🟩 Забронировать", "toggle_reserve:#{item.id}")
        elsif item.reserved_by == user.telegram_id
          row << context.inline_btn("🟨 Снять резерв", "toggle_reserve:#{item.id}")
        else
          row << context.inline_btn("🔴 Занято", "noop")
        end

        buttons << row

        # Owner-only buttons
        if owner?
          buttons << [
            context.inline_btn("✏️ Редактировать", "edit_item:#{item.id}"),
            context.inline_btn("🗑 Удалить", "delete_item:#{item.id}")
          ]
        end

        buttons
      end

      def owner?
        item.wishlist.user_id == user.id
      end
    end
  end
end
