module Bot
  module Callbacks
    extend Bot::Helpers

    CALLBACK_ROUTES = {
      /^main_menu$/ => "Callbacks::WishlistHandler#main_menu",
      /^settings$/ => "Callbacks::SettingsHandler#show_settings",
      /^set_setting:(\w+):([01])$/ => "Callbacks::SettingsHandler#set_setting",
      /^reservation_reminders$/ => "Callbacks::SettingsHandler#show_reservation_reminders",
      /^set_reminder_days:(0|7|14|30)$/ => "Callbacks::SettingsHandler#set_reminder_days",
      /^help$/ => "Callbacks::HelpHandler#show_help",
      /^resume_input$/ => "Callbacks::InputHandler#resume",
      /^cancel_input$/ => "Callbacks::InputHandler#cancel",
      /^show_reservations$/ => "Callbacks::ReservationsHandler#show_reservations",
      /^show_reservations:(\d+)$/ => "Callbacks::ReservationsHandler#show_reservations",
      /^open_booked_item:(\d+):(\d+)$/ => "Callbacks::ReservationsHandler#open_item",
      /^release_book:(\d+):(\d+):(\d+)$/ => "Callbacks::ReservationsHandler#release",
      /^show_lists$/ => "Callbacks::WishlistHandler#show_lists",
      /^show_lists:(\d+)$/ => "Callbacks::WishlistHandler#show_lists",
      /^show_shared_lists$/ => "Callbacks::WishlistHandler#show_shared_lists",
      /^show_shared_lists:(\d+)$/ => "Callbacks::WishlistHandler#show_shared_lists",
      /^new_list$/ => "Callbacks::WishlistHandler#create_list_prompt",
      /^list_settings:(\d+)$/ => "Callbacks::WishlistHandler#list_settings",
      /^rename_list:(\d+)$/ => "Callbacks::WishlistHandler#rename_list_prompt",
      /^confirm_delete_list:(\d+)$/ => "Callbacks::WishlistHandler#confirm_delete_list",
      /^delete_list:(\d+)$/ => "Callbacks::WishlistHandler#delete_list",
      /^open_list:(\d+)$/ => "Callbacks::WishlistHandler#open_list",
      /^list_page:(\d+):(\d+)$/ => "Callbacks::WishlistHandler#open_list",
      /^open_shared_list:(\d+)$/ => "Callbacks::WishlistHandler#open_shared_list",

      /^open_item:(\d+)$/ => "Callbacks::ItemHandler#show_item",
      /^add_item:(\d+)$/ => "Callbacks::ItemHandler#add_item_prompt",
      /^edit_item:(\d+)$/ => "Callbacks::ItemHandler#edit_item_menu",
      /^edit_item_field:(.+):(\d+)$/ => "Callbacks::ItemHandler#edit_item_field_prompt",
      /^reserve_item:(\d+):(\d+)$/ => "Callbacks::ItemHandler#reserve_item",
      /^unreserve_item:(\d+):(\d+)$/ => "Callbacks::ItemHandler#unreserve_item",
      /^mark_purchased:(\d+):(\d+):([01])$/ => "Callbacks::ItemHandler#mark_purchased",
      /^mark_purchased:(\d+):(\d+):([01]):(\d+)$/ => "Callbacks::ItemHandler#mark_purchased",
      /^thank_reserver:(\d+):(\d+)$/ => "Callbacks::ItemHandler#thank_reserver",
      /^toggle_reserve:(\d+)$/ => "Callbacks::ItemHandler#toggle_reserve",
      /^confirm_delete_item:(\d+)$/ => "Callbacks::ItemHandler#confirm_delete_item",
      /^delete_item:(\d+)$/ => "Callbacks::ItemHandler#delete_item",
      /^clear_item_field:(\w+):(\d+)$/ => "Callbacks::ItemHandler#clear_item_field",
      /^skip_item_url(?::(\w+))?$/ => "Callbacks::ItemHandler#skip_item_url"
    }.freeze

    # Buttons that finish the pending input, do nothing, or only look
    # something up (help, settings), so they keep it
    KEEP_INPUT_CALLBACKS = /\A(skip_item_url(:\w+)?|noop|help|settings|set_setting:\w+:[01]|reservation_reminders|set_reminder_days:(0|7|14|30)|resume_input|cancel_input)\z/

    class << self
      def handle(bot, callback)
        user = User.find_or_create_from_telegram(callback.from.to_h.symbolize_keys)

        # Buttons in inline messages sent before share tokens carry a list id.
        # Callback data comes from the client and proves nothing, so the id
        # opens the list only for people who already have access to it.
        if callback.inline_message_id && (match = callback.data.match(/^open_shared_list:(\d+)$/))
          wishlist = Wishlist.accessible_to(user).find_by(id: match[1])
          answer(bot, callback,
                 url: wishlist && share_link(wishlist),
                 text: (I18n.t("bot.commands.link_outdated") unless wishlist),
                 show_alert: (true unless wishlist))
          return
        end

        context = Context.new(bot: bot, user: user, source: callback)

        # Pressing a button abandons any pending input, prompts start a new one
        user.clear_state! if user.bot_state.present? && !KEEP_INPUT_CALLBACKS.match?(callback.data.to_s)

        route_callback(context)
        answer(bot, callback, text: context.notice)
      # Problems with a button show up as a popup on that button, not as
      # chat messages that stay under the screen
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.warn("Record not found in callback handler: #{e.message}")
        answer(bot, callback, text: I18n.t("bot.messages.not_available"), show_alert: true)
      rescue StandardError => e
        raise if UpdateDelivery.current

        Rails.logger.error("Error in callback handler: #{e.message}\n#{e.backtrace.join("\n")}")
        answer(bot, callback, text: I18n.t("bot.messages.error"), show_alert: true)
      end

      # Public interface for other services
      def open_list(*args)
        context, wishlist_id = prepare_context_and_id(*args)
        Callbacks::WishlistHandler.new(context).open_list(wishlist_id)
      end

      def open_shared_list(*args)
        context, wishlist_id = prepare_context_and_id(*args)
        Callbacks::WishlistHandler.new(context).open_shared_list(wishlist_id)
      end

      def show_lists(context)
        Callbacks::WishlistHandler.new(context).show_lists
      end

      private

      # A repeated or late update carries a callback that can't be answered
      # anymore; the screen is already updated, so this is not the user's problem
      def answer(bot, callback, **options)
        if (delivery = UpdateDelivery.current)
          return delivery.defer { answer(bot, callback, **options) }
        end

        bot.api.answer_callback_query(callback_query_id: callback.id, **options.compact)
      rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
        Rails.logger.warn("Could not answer callback query: #{e.message}")
      end

      def route_callback(context)
        data = context.callback_data
        CALLBACK_ROUTES.each do |pattern, handler_string|
          next unless (match = pattern.match(data))

          handler_class_name, method_name = handler_string.split("#")
          params = match.captures.map { |c| c =~ /^\d+$/ ? c.to_i : c }

          handler_class = "Bot::#{handler_class_name}".constantize
          handler_class.new(context).public_send(method_name, *params)
          return
        end
      end

      def prepare_context_and_id(bot, user, chat_id, wishlist_id)
        # This method is now simpler, it just constructs a context from raw parts
        # when called from an external service like Commands.
        # The `chat` part of the source is not fully correct, but it works for `chat_id` retrieval.
        source = Telegram::Bot::Types::CallbackQuery.new(from: user, message: { chat: { id: chat_id } })
        context = Context.new(bot: bot, user: user, source: source)
        [ context, wishlist_id ]
      end
    end
  end
end
