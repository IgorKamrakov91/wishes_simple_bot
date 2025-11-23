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

        if user.bot_state == "adding_item_url"
          return create_item_url(bot, user, chat_id, text)
        end

        if user.bot_state == "editing_item"
          return update_item_field(bot, user, chat_id, text)
        end

        case text
        when /^\/start list_(\d+)$/
          wishlist_id = text.match(/^\/start list_(\d+)$/)[1].to_i
          handle_shared_list(bot, user, chat_id, wishlist_id)
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

      def handle_shared_list(bot, user, chat_id, wishlist_id)
        wishlist = Wishlist.find_by(id: wishlist_id)

        unless wishlist
          send_text(bot, chat_id, "Список не найден.")
          return
        end

        # Add user to viewers and open the list
        Callbacks.open_shared_list(bot, user, chat_id, wishlist_id)
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
      end

      def create_item(bot, user, chat_id, text)
        wishlist_id = user.bot_payload["wishlist_id"]
        wishlist = user.wishlists.find(wishlist_id)
        item = wishlist.items.create!(title: text)

        user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => wishlist.id })

        send_text(bot, chat_id, "Введите URL для подарка (или '-' если пропустить):")
      end

      def create_item_url(bot, user, chat_id, text)
        item = Item.find(user.bot_payload["item_id"])
        wishlist_id = user.bot_payload["wishlist_id"]

        url = text == "-" ? nil : text
        item.update!(url: url)

        user.clear_state!

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [ inline_btn("Добавить ещё", "add_item:#{wishlist_id}") ],
            [ inline_btn("Открыть список", "open_list:#{wishlist_id}") ]
          ]
        )

        send_text(bot, chat_id, "Подарок успешно добавлен!", keyboard)
      end

      def update_item_field(bot, user, chat_id, text)
        item = Item.find(user.bot_payload["item_id"])
        field = user.bot_payload["field"]

        if field == "price"
          text = text.gsub(",", ".").to_f
        end

        item.update!(field => text)

        user.clear_state!

        wishlist_id = item.wishlist_id

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [ inline_btn("Редактировать ещё", "edit_item:#{item.id}") ],
            [ inline_btn("Открыть список", "open_list:#{wishlist_id}") ]
          ]
        )

        send_text(bot, chat_id, "Поле «#{field}» обновлено!", keyboard)
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
