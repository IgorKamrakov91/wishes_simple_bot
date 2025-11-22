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
          [ inline_btn(list.title, "open_list:#{list.id}") ]
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)

        send_text(bot, chat_id, "Мои списки:", keyboard)
      end

      def create_list_prompt(bot, user, chat_id)
        user.start_creating_list!

        send_text(bot, chat_id, "Введите название списка:")
      end

      def open_list(bot, user, chat_id, list_id)
        wishlist  = user.wishlists.find(list_id)
        items = wishlist.items.order(created_at: :asc)

        if items.empty?
          text = "Список «#{wishlist.title}» пуст.\nДобавьте первый подарок:"
        else
          text = "Список «#{wishlist.title}»:\n\n"
          items.each do |item|
            mark = item.reserved_by ? "🔒" : "🎁"
            text << "#{mark} #{item.title}\n"
          end
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [ inline_btn("Добавить подарок", "add_item:#{wishlist.id}") ],
            [ inline_btn("Мои списки", "show_lists") ]
          ]
        )

        send_text(bot, chat_id, text, keyboard)
      end
    end
  end
end
