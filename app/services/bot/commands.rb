module Bot
  class Commands
    extend Bot::Helpers

    class << self
      def handle(bot, message)
        user = User.find_or_create_from_telegram(message.from.to_h.symbolize_keys)
        chat_id = message.chat.id
        text = message.text.to_s.strip || ""

        if user.bot_state == "creating_list"
          return create_list(bot, user, chat_id, text)
        end

        if user.bot_state == "renaming_list"
          return rename_list(bot, user, chat_id, text)
        end

        if user.bot_state == "adding_item"
          return create_item(bot, user, chat_id, text)
        end

        case text
        when "/start"
          handle_start(bot, user, chat_id)
        when "/help"
          send_text(bot, chat_id, help_text)
        when "/my"
          Callbacks.show_lists(bot, user, chat_id)
        else
          puts "IGNORE"
        end
      end

      def handle_start(bot, user, chat_id)
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [ inline_btn("Мои списки", "show_lists") ],
            [ inline_btn("Создать список", "new_list") ]
          ]
        )

        send_text(bot, chat_id, "Привет, #{user.first_name}!\nЯ помогу тебе вести вишлисты.", keyboard)
      end

      def create_list(bot, user, chat_id, text)
        wishlist = user.wishlists.create!(title: text)

        user.clear_state!

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [ inline_btn("Добавить подарок", "add_item:#{wishlist.id}") ],
            [ inline_btn("Мои списки", "show_lists") ]
          ]
        )

        send_text(bot, chat_id, "Список #{wishlist.title} создан!", keyboard)
      end

      def rename_list(bot, user, chat_id, text)
        wishlist_id = user.bot_payload["wishlist_id"]
        wishlist = user.wishlists.find(wishlist_id)

        wishlist.update!(title: text)
        user.clear_state!

        send_text(bot, chat_id, "Название списка изменено!")

        Callbacks.open_list(bot, user, chat_id, wishlist_id)
      end

      def create_item(bot, user, chat_id, text)
        wishlist_id = user.bot_payload["wishlist_id"]
        wishlist = user.wishlists.find(wishlist_id)
        item = wishlist.items.create!(title: text)

        user.clear_state!

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [ inline_btn("Добавить еще подарок", "add_item:#{wishlist.id}") ],
            [ inline_btn("Вернуться к списку", "open_list:#{wishlist.id}") ]
          ]
        )

        send_text(bot, chat_id, "Подарок #{item.title} добавлен!", keyboard)
      end

      def help_text
        <<~TEXT
          Доступные команды:
          /start — начать
          /my — мои списки
          (Основное управление — через кнопки)
        TEXT
      end
    end
  end
end
