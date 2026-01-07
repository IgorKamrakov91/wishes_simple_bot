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
        Rails.logger.info "Bot::Commands received text: '#{context.text.inspect}'"
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
            [ inline_btn(I18n.t("bot.buttons.my_lists"), "show_lists") ],
            [ inline_btn(I18n.t("bot.buttons.create_list"), "new_list") ],
            [ inline_btn(I18n.t("bot.buttons.shared_lists"), "show_shared_lists") ]
          ]
        )

        context.send_text(I18n.t("bot.commands.hello", name: context.user.first_name), keyboard)
      end

      def handle_shared_list(context, wishlist_id)
        wishlist = Wishlist.find_by(id: wishlist_id)

        unless wishlist
          context.send_text(I18n.t("bot.commands.list_not_found"))
          return
        end

        # Using the public interface of Callbacks service
        Callbacks::WishlistHandler.new(context).open_shared_list(wishlist_id)
      end

      def help_text
        I18n.t("bot.commands.help")
      end
    end
  end
end
