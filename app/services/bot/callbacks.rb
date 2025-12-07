module Bot
  module Callbacks
    extend Bot::Helpers

    CALLBACK_ROUTES = {
      /^show_lists$/ => "Callbacks::WishlistHandler#show_lists",
      /^new_list$/ => "Callbacks::WishlistHandler#create_list_prompt",
      /^rename_list:(\d+)$/ => "Callbacks::WishlistHandler#rename_list_prompt",
      /^delete_list:(\d+)$/ => "Callbacks::WishlistHandler#delete_list",
      /^open_list:(\d+)$/ => "Callbacks::WishlistHandler#open_list",
      /^open_shared_list:(\d+)$/ => "Callbacks::WishlistHandler#open_shared_list",

      /^add_item:(\d+)$/ => "Callbacks::ItemHandler#add_item_prompt",
      /^edit_item:(\d+)$/ => "Callbacks::ItemHandler#edit_item_menu",
      /^edit_item_field:(.+):(\d+)$/ => "Callbacks::ItemHandler#edit_item_field_prompt",
      /^toggle_reserve:(\d+)$/ => "Callbacks::ItemHandler#toggle_reserve",
      /^delete_item:(\d+)$/ => "Callbacks::ItemHandler#delete_item"
    }.freeze

    class << self
      def handle(bot, callback)
        user = User.find_or_create_from_telegram(callback.from.to_h.symbolize_keys)

        # Check if a callback is from an inline message
        if callback.inline_message_id && callback.data.match?(/^open_shared_list:(\d+)$/)
          wishlist_id = callback.data.match(/^open_shared_list:(\d+)$/)[1]

          # Get bot username - API returns hash with 'result' key
          response = bot.api.call("getMe")
          bot_username = response["result"]["username"]

          url = "https://t.me/#{bot_username}?start=list_#{wishlist_id}"
          Rails.logger.info "Bot::Callbacks answering callback with URL: '#{url}'"
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            url: url
          )
          return
        end

        context = Context.new(bot: bot, user: user, source: callback)

        route_callback(context)
        bot.api.answer_callback_query(callback_query_id: callback.id)
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
