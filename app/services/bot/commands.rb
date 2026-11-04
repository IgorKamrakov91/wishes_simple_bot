module Bot
  class Commands
    START_SHARED_LIST_PATTERN = %r{\A/start list_(\d+)\z}

    extend Bot::Helpers

    class << self
      def handle(bot, message)
        user = User.find_or_create_from_telegram(message.from.to_h.symbolize_keys)
        context = Context.new(bot: bot, user: user, source: message)

        if user.bot_state.present?
          # A command means the user gave up on the pending input
          unless context.text.start_with?("/")
            StateHandler.new(context).handle
            return
          end

          user.clear_state!
        end

        # Otherwise, handle as a command
        text = context.text
        Rails.logger.info "Bot::Commands received text: #{text.inspect}"

        if (match = START_SHARED_LIST_PATTERN.match(text))
          handle_shared_list(context, match[1].to_i)
          return
        end

        case text
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
        Callbacks::WishlistHandler.new(context).main_menu
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
