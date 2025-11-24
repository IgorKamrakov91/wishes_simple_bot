module Bot
  class Commands
    extend Bot::Helpers

    class << self
      def handle(bot, message)
        user = User.find_or_create_from_telegram(message.from.to_h.symbolize_keys)
        context = Context.new(bot: bot, user: user, source: message)

        # If user is in a state, delegate to the state handler
        if user.bot_state.present?
          StateHandler.new(context).handle
          return
        end

        # Otherwise, handle as a command
        case context.text
        when /^\/start list_(\d+)$/
          wishlist_id = context.text.match(/^\/start list_(\d+)$/)[1].to_i
          handle_shared_list(context, wishlist_id)
        when "/start"
          handle_start(context)
        when "/help"
          context.send_text(help_text)
        when "/my"
          Callbacks.show_lists(context)
        else
          # Ignoring other messages
          Rails.logger.info "Ignoring message from #{user.id}: #{context.text}"
        end
      end

      private

      def handle_start(context)
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [inline_btn("Мои списки", "show_lists")],
            [inline_btn("Создать список", "new_list")]
          ]
        )

        context.send_text("Привет, #{context.user.first_name}!\nЯ помогу тебе вести вишлисты.", keyboard)
      end

      def handle_shared_list(context, wishlist_id)
        wishlist = Wishlist.find_by(id: wishlist_id)

        unless wishlist
          context.send_text("Список не найден.")
          return
        end

        # Using the public interface of Callbacks service
        Callbacks.open_shared_list(context, wishlist_id)
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
