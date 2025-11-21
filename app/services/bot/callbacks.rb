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
        send_text(bot, chat_id, "Мои списки:")
      end

      def create_list_prompt(bot, user, chat_id)
        send_text(bot, chat_id, "Введите название списка:")
      end

      def open_list(bot, user, chat_id, list_id)
        send_text(bot, chat_id, "Открываю список ID=#{list_id}")
      end
    end
  end
end