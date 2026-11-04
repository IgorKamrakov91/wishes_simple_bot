module Bot
  module Callbacks
    extend Bot::Helpers

    CALLBACK_ROUTES = {
      /^main_menu$/ => "Callbacks::WishlistHandler#main_menu",
      /^show_lists$/ => "Callbacks::WishlistHandler#show_lists",
      /^show_shared_lists$/ => "Callbacks::WishlistHandler#show_shared_lists",
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
      /^toggle_reserve:(\d+)$/ => "Callbacks::ItemHandler#toggle_reserve",
      /^confirm_delete_item:(\d+)$/ => "Callbacks::ItemHandler#confirm_delete_item",
      /^delete_item:(\d+)$/ => "Callbacks::ItemHandler#delete_item",
      /^skip_item_url$/ => "Callbacks::ItemHandler#skip_item_url"
    }.freeze

    # Buttons that finish the pending input instead of abandoning it
    INPUT_CALLBACKS = %w[skip_item_url].freeze

    class << self
      def handle(bot, callback)
        user = User.find_or_create_from_telegram(callback.from.to_h.symbolize_keys)

        # Check if a callback is from an inline message
        if callback.inline_message_id && (match = callback.data.match(/^open_shared_list:(\d+)$/))
          # The button sits in a message the owner shared, so it hands out the share link
          wishlist = Wishlist.find_by(id: match[1])
          bot.api.answer_callback_query(**{
            callback_query_id: callback.id,
            url: wishlist && share_link(wishlist),
            text: (I18n.t("bot.commands.list_not_found") unless wishlist)
          }.compact)
          return
        end

        context = Context.new(bot: bot, user: user, source: callback)

        # Pressing a button abandons any pending input, prompts start a new one
        user.clear_state! if user.bot_state.present? && !INPUT_CALLBACKS.include?(callback.data)

        route_callback(context)
        bot.api.answer_callback_query(**{ callback_query_id: callback.id, text: context.notice }.compact)
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.error("Record not found in callback handler: #{e.message}")
        context&.send_text(I18n.t("bot.messages.error"))
        bot.api.answer_callback_query(callback_query_id: callback.id) rescue nil
      rescue StandardError => e
        Rails.logger.error("Error in callback handler: #{e.message}\n#{e.backtrace.join("\n")}")
        context&.send_text(I18n.t("bot.messages.error"))
        bot.api.answer_callback_query(callback_query_id: callback.id) rescue nil
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
