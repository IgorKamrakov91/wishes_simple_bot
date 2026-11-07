module Bot
  class Commands
    START_SHARED_LIST_PATTERN = %r{\A/start l_([A-Za-z0-9]+)\z}
    # Links from before share tokens: they no longer let anyone in
    START_LEGACY_LIST_PATTERN = %r{\A/start list_(\d+)\z}

    # Only intentional navigation abandons input. Help, settings and command
    # typos keep the draft so the next answer can still finish it.
    EXIT_INPUT_COMMANDS = %w[/start /my /new /reservations /cancel].freeze

    extend Bot::Helpers

    class << self
      def handle(bot, message)
        user = User.find_or_create_from_telegram(message.from.to_h.symbolize_keys)
        context = Context.new(bot: bot, user: user, source: message)

        had_input = user.bot_state.present?
        if had_input
          unless context.text.start_with?("/")
            StateHandler.new(context).handle
            return
          end

          if EXIT_INPUT_COMMANDS.include?(context.text) ||
              START_SHARED_LIST_PATTERN.match?(context.text) || START_LEGACY_LIST_PATTERN.match?(context.text)
            user.clear_state!
          end
        end

        # Otherwise, handle as a command
        text = context.text

        if (match = START_SHARED_LIST_PATTERN.match(text))
          handle_shared_list(context, match[1])
          return
        end

        if (match = START_LEGACY_LIST_PATTERN.match(text))
          handle_legacy_link(context, match[1].to_i)
          return
        end

        case text
        when "/start"
          handle_start(context)
        when "/help"
          Callbacks::HelpHandler.new(context).show_help
        when "/my"
          Callbacks.show_lists(context)
        when "/new"
          Callbacks::WishlistHandler.new(context).create_list_prompt
        when "/reservations"
          Callbacks::ReservationsHandler.new(context).show_reservations
        when "/settings"
          Callbacks::SettingsHandler.new(context).show_settings
        when "/cancel"
          reply_with_menu(context, I18n.t(had_input ? "bot.commands.cancelled" : "bot.commands.nothing_to_cancel"))
        else
          handle_unrecognized(context)
        end
      rescue StandardError => e
        # Exception messages can contain submitted values, SQL or invitation
        # tokens. Keep the error kind without logging their private contents.
        Rails.logger.error("Bot message handling failed (#{e.class})")
        reply_after_error(bot, message)
      end

      private

      # Never stay silent in a private chat; in groups only commands get answers
      def handle_unrecognized(context)
        return unless context.source.chat&.type == "private"

        key = if context.text.start_with?("/") then "unknown_command"
        elsif context.text.empty? then "text_only"
        else "unrecognized_text"
        end
        text = I18n.t("bot.commands.#{key}")
        text = "#{text}\n#{Profile.command_list}" if key == "unknown_command"
        reply_with_menu(context, text)
      end

      def reply_with_menu(context, text)
        prompt = InputPrompt.new(context)
        rows = prompt.resume_rows
        rows << [ inline_btn(I18n.t("bot.buttons.my_lists"), "show_lists"), inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]
        context.send_text(prompt.with_input_note(text), build_keyboard(rows))
      end

      def recovery_navigation
        [ inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu"), inline_btn(I18n.t("bot.buttons.help"), "help") ]
      end

      def reply_after_error(bot, message)
        return unless message.chat&.type == "private"

        rows = [
          [ inline_btn(I18n.t("bot.buttons.my_lists"), "show_lists"),
            inline_btn(I18n.t("bot.screens.reservations.title"), "show_reservations") ],
          recovery_navigation
        ]
        # Recovery must also work when finding the user failed. Sending this
        # neutral response needs neither a database lookup nor a state change.
        context = Context.new(bot: bot, user: nil, source: message)
        context.send_text(I18n.t("bot.commands.message_failed"), build_keyboard(rows))
      rescue StandardError => e
        # Telegram may be unavailable too. A failed fallback must not turn an
        # already handled update into a replay of a possibly committed action.
        Rails.logger.warn("Bot message fallback failed (#{e.class})")
      end

      def reply_with_unavailable_invitation(context)
        context.send_text(I18n.t("bot.commands.invitation_unavailable"), build_keyboard([ recovery_navigation ]))
      end

      def handle_start(context)
        Callbacks::WishlistHandler.new(context).main_menu
      end

      def handle_shared_list(context, token)
        wishlist = Wishlist.find_by(share_token: token)

        unless wishlist
          reply_with_unavailable_invitation(context)
          return
        end

        wishlist.admit!(context.user)
        Callbacks::WishlistHandler.new(context).open_list(wishlist.id)
      end

      # Old id links still work for people who already have access
      def handle_legacy_link(context, wishlist_id)
        if Wishlist.accessible_to(context.user).exists?(wishlist_id)
          Callbacks::WishlistHandler.new(context).open_list(wishlist_id)
        else
          reply_with_unavailable_invitation(context)
        end
      end
    end
  end
end
