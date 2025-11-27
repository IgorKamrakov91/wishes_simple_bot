# frozen_string_literal: true

module Bot
  module Callbacks
    class WishlistHandler < BaseHandler
      def show_lists
        lists = user.wishlists

        if lists.empty?
          context.send_text(
            "У вас пока нет вишлистов. Создайте первый 👉",
            context.build_keyboard([ [ context.inline_btn("Создать список", "new_list") ] ])
          )
          return
        end

        buttons = lists.map do |list|
          [
            context.inline_btn(list.title, "open_list:#{list.id}"),
            context.inline_btn("🔗 Поделиться", nil, switch_inline_query: "share_#{list.id}")
          ]
        end
        buttons << [ context.inline_btn("➕ Создать новый список", "new_list") ]
        context.send_text("Мои списки:", context.build_keyboard(buttons))
      end

      def create_list_prompt
        user.start_creating_list!
        context.send_text("Введите название списка:")
      end

      def rename_list_prompt(wishlist_id)
        user.start_renaming_list!(wishlist_id: wishlist_id)
        context.send_text("Введите новое название списка:")
      end

      def delete_list(wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)
        wishlist.destroy!

        context.send_text("Список удален!")
        show_lists
      end

      def open_list(wishlist_id)
        wishlist = Wishlist.find(wishlist_id)
        is_owner = wishlist.user_id == user.id

        add_user_to_list_viewers(user, wishlist) unless is_owner

        # Send header
        context.send_text("🎉 Список: #{wishlist.title}\n")

        # Send each item with its buttons
        if wishlist.items.empty?
          context.send_text("Пока пусто. Добавьте первый подарок!")
        else
          wishlist.items.each do |item|
            presenter = Presenters::ItemPresenter.new(item, user, context)
            context.send_text(presenter.text, presenter.keyboard)
          end
        end

        # Send list management buttons
        presenter = Presenters::WishlistPresenter.new(wishlist, user, context)
        context.send_text("⚙️ Управление списком:", presenter.management_keyboard)
      end

      def open_shared_list(wishlist_id)
        wishlist = Wishlist.find(wishlist_id)
        Rails.logger.info("Shared list opened: #{wishlist.inspect}")
        # wishlist.list_viewers.find_or_create_by!(user: user)

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
