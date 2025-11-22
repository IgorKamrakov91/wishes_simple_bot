module Bot
  class Callbacks
    extend Bot::Helpers

    class << self
      def handle(bot, callback)
        data = callback.data
        user = User.find_or_create_from_telegram(callback.from.to_h.symbolize_keys)
        chat_id = callback.message.chat.id

        case data
        when "show_lists"
          show_lists(bot, user, chat_id)
        when "new_list"
          create_list_prompt(bot, user, chat_id)
        when /^rename_list:(\d+)$/
          rename_list(bot, user, chat_id, $1.to_i)
        when /^delete_list:(\d+)$/
          delete_list(bot, user, chat_id, $1.to_i)
        when /^add_item:(\d+)$/
          wishlist_id = $1.to_i
          add_item_prompt(bot, user, chat_id, wishlist_id)
        when /^toggle_reserve:(\d+)$/
          toggle_reserve(bot, user, chat_id, $1.to_i)
        when /^delete_item:(\d+)$/
          delete_item(bot, user, chat_id, $1.to_i)
        else
          if data.start_with?("open_list:")
            open_list(bot, user, chat_id, data.split(":")[1].to_i)
          end
        end

        bot.api.answer_callback_query(callback_query_id: callback.id)
      end

      def show_lists(bot, user, chat_id)
        lists = user.wishlists

        if lists.empty?
          send_text(
            bot, chat_id, "У вас пока нет вишлистов. Создайте первый 👉",
            Telegram::Bot::Types::InlineKeyboardMarkup.new(
              inline_keyboard: [
                [inline_btn("Создать список", "new_list")]
              ]
            )
          )

          return
        end

        buttons = lists.map do |list|
          [inline_btn(list.title, "open_list:#{list.id}")]
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)

        send_text(bot, chat_id, "Мои списки:", keyboard)
      end

      def create_list_prompt(bot, user, chat_id)
        user.start_creating_list!

        send_text(bot, chat_id, "Введите название списка:")
      end

      def open_list(bot, user, chat_id, id)
        wishlist = user.wishlists.find(id)

        if wishlist.items.empty?
          text = "Список «#{wishlist.title}» пуст.\nДобавьте подарок:"
        else
          text = "🎉 Список «#{wishlist.title}»:\n\n"

          wishlist.items.each do |item|
            mark = item.reserved_by ? "🔒 (#{item.reserved_by})" : "🎁"
            text << "#{mark} #{item.title}\n"
          end
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [inline_btn("Добавить подарок", "add_item:#{wishlist.id}")],
            [inline_btn("Переименовать список", "rename_list:#{wishlist.id}")],
            [inline_btn("Удалить список", "delete_list:#{wishlist.id}")],

            *wishlist.items.map { |i| item_buttons(i) },

            [inline_btn("Мои списки", "show_lists")]
          ]
        )

        send_text(bot, chat_id, text, keyboard)
      end

      def rename_list_prompt(bot, user, chat_id, wishlist_id)
        user.start_renaming_list!(wishlist_id: wishlist_id)
        send_text(bot, chat_id, "Введите новое название списка:")
      end

      def delete_list(bot, user, chat_id, wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)
        wishlist.destroy!

        send_text(bot, chat_id, "Список удален!")
        show_lists(bot, user, chat_id)
      end

      def add_item_prompt(bot, user, chat_id, wishlist_id)
        user.start_adding_item!(wishlist_id: wishlist_id)
        send_text(bot, chat_id, "Введите название подарка:")
      end

      def item_buttons(item)
        [
          inline_btn("✏️ #{item.title}", "edit_item:#{item.id}"),
          inline_btn(item.reserved_by ? "🔓 снять резерв" : "🔒 забронировать", "toggle_reserve:#{item.id}"),
          inline_btn("🗑 удалить", "delete_item:#{item.id}")
        ]
      end

      def toggle_reserve(bot, user, chat_id, item_id)
        item = Item.find(item_id)

        if item.reserved_by
          item.update!(reserved_by: nil)

          notify_viewers(item.wishlist, "🔓 Резерв снят с «#{item.title}»")
          send_text(bot, chat_id, "Вы сняли резерв с «#{item.title}»")
        else
          item.update!(reserved_by: user.telegram_id)

          notify_viewers(item.wishlist, "🔒 «#{item.title}» забронирован пользователем @#{user.username}")
          send_text(bot, chat_id, "Вы забронировали «#{item.title}»")
        end
      end

      def delete_item(bot, user, chat_id, item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist

        item.destroy!

        notify_viewers(wishlist, "🗑 «#{item.title}» удален")
        send_text(bot, chat_id, "Подарок удален!")

        open_list(bot, user, chat_id, wishlist.id)
      end

      def notify_viewers(wishlist, message)
        wishlist.list_viewers.each do |viewer|
          bot = Telegram::Bot::Client.new("8179126467:AAFWyk5lQ9cOZSAHvyaNGfBppR6udi2ohx8")
          bot.api.send_message(chat_id: viewer.telegram_id, text: message)
        end
      end
    end
  end
end
