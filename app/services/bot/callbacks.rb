module Bot
  class Callbacks
    extend Bot::Helpers

    # Context object to encapsulate common parameters
    class Context
      include Bot::Helpers

      attr_reader :bot, :user, :chat_id

      def initialize(bot, user, chat_id)
        @bot = bot
        @user = user
        @chat_id = chat_id
      end

      def send_text(text, keyboard = nil)
        super(bot, chat_id, text, keyboard)
      end
    end

    CALLBACK_ROUTES = {
      /^show_lists$/ => :show_lists,
      /^new_list$/ => :create_list_prompt,
      /^rename_list:(\d+)$/ => :rename_list_prompt,
      /^delete_list:(\d+)$/ => :delete_list,
      /^add_item:(\d+)$/ => :add_item_prompt,
      /^edit_item:(\d+)$/ => :edit_item_menu,
      /^edit_item_field:(.+):(\d+)$/ => :edit_item_field_prompt,
      /^toggle_reserve:(\d+)$/ => :toggle_reserve,
      /^delete_item:(\d+)$/ => :delete_item,
      /^open_shared_list:(\d+)$/ => :open_shared_list,
      /^open_list:(\d+)$/ => :open_list
    }.freeze

    class << self
      def handle(bot, callback)
        user = User.find_or_create_from_telegram(callback.from.to_h.symbolize_keys)
        chat_id = callback.message&.chat&.id || callback.from.id
        context = Context.new(bot, user, chat_id)

        route_callback(context, callback.data)
        bot.api.answer_callback_query(callback_query_id: callback.id)
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.error("Record not found in callback handler: #{e.message}")
        context&.send_text("Произошла ошибка. Попробуйте еще раз.")
        bot.api.answer_callback_query(callback_query_id: callback.id) rescue nil
      rescue StandardError => e
        Rails.logger.error("Error in callback handler: #{e.message}\n#{e.backtrace.join("\n")}")
        context&.send_text("Произошла ошибка. Попробуйте еще раз.")
        bot.api.answer_callback_query(callback_query_id: callback.id) rescue nil
      end

      def open_list(*args)
        # Support two calling conventions:
        # 1) open_list(context, wishlist_id)
        # 2) open_list(bot, user, chat_id, wishlist_id)
        if args.size == 2 && args[0].is_a?(Context)
          context, wishlist_id = args
        elsif args.size == 4
          bot, user, chat_id, wishlist_id = args
          context = Context.new(bot, user, chat_id)
        else
          raise ArgumentError, "open_list expects (context, wishlist_id) or (bot, user, chat_id, wishlist_id)"
        end

        wishlist = Wishlist.find(wishlist_id)
        is_owner = wishlist.user_id == context.user.id

        add_user_to_list_viewers(context.user, wishlist) unless is_owner

        # Send header
        context.send_text("🎉 Список: #{wishlist.title}\n")

        # Send each item with its buttons
        if wishlist.items.empty?
          context.send_text("Пока пусто. Добавьте первый подарок!")
        else
          wishlist.items.each do |item|
            item_text = build_item_text(item)
            item_buttons = build_item_buttons(context, item, is_owner)
            context.send_text(item_text, build_keyboard(item_buttons))
          end
        end

        # Send list management buttons
        list_buttons = build_list_management_buttons(context, wishlist, is_owner)
        context.send_text("⚙️ Управление списком:", build_keyboard(list_buttons))
      end

      private

      def route_callback(context, data)
        CALLBACK_ROUTES.each do |pattern, method_name|
          if (match = pattern.match(data))
            params = match.captures.map { |capture| capture =~ /^\d+$/ ? capture.to_i : capture }
            send(method_name, context, *params)
            return
          end
        end
      end

      def show_lists(context)
        lists = context.user.wishlists

        if lists.empty?
          context.send_text(
            "У вас пока нет вишлистов. Создайте первый 👉",
            build_keyboard([[context.inline_btn("Создать список", "new_list")]])
          )
          return
        end

        buttons = lists.map { |list| [context.inline_btn(list.title, "open_list:#{list.id}")] }
        context.send_text("Мои списки:", build_keyboard(buttons))
      end

      def create_list_prompt(context)
        context.user.start_creating_list!
        context.send_text("Введите название списка:")
      end

      def rename_list_prompt(context, wishlist_id)
        context.user.start_renaming_list!(wishlist_id: wishlist_id)
        context.send_text("Введите новое название списка:")
      end

      def delete_list(context, wishlist_id)
        wishlist = context.user.wishlists.find(wishlist_id)
        wishlist.destroy!

        context.send_text("Список удален!")
        show_lists(context)
      end

      def add_item_prompt(context, wishlist_id)
        context.user.start_adding_item!(wishlist_id: wishlist_id)
        context.send_text("Введите название подарка:")
      end

      def edit_item_menu(context, item_id)
        item = Item.find(item_id)

        buttons = [
          [context.inline_btn("Название", "edit_item_field:title:#{item.id}")],
          [context.inline_btn("Описание", "edit_item_field:description:#{item.id}")],
          [context.inline_btn("URL", "edit_item_field:url:#{item.id}")],
          [context.inline_btn("Цена", "edit_item_field:price:#{item.id}")]
        ]

        context.send_text("Что хотите изменить для «#{item.title}»?", build_keyboard(buttons))
      end

      def edit_item_field_prompt(context, field, item_id)
        context.user.update!(
          bot_state: "editing_item",
          bot_payload: { item_id: item_id, field: field }
        )

        context.send_text("Введите новое значение поля «#{field}»:")
      end

      def toggle_reserve(context, item_id)
        item = Item.find(item_id)

        if item.reserved_by && item.reserved_by != context.user.telegram_id
          context.send_text("Этот подарок забронирован другим пользователем.")
          return
        end

        if item.reserved_by == context.user.telegram_id
          unreserve_item(context, item)
        else
          reserve_item(context, item)
        end
      end

      def delete_item(context, item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist
        item_title = item.title

        item.destroy!

        notify_viewers(wishlist, "🗑 «#{item_title}» удален")
        context.send_text("Подарок удален!")

        open_list(context, wishlist.id)
      end

      def open_shared_list(context, wishlist_id)
        wishlist = Wishlist.find(wishlist_id)
        wishlist.list_viewers.find_or_create_by!(user: context.user)

        open_list(context, wishlist_id)
      end

      # Helper methods for building UI components

      def build_keyboard(buttons)
        Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
      end

      def build_item_text(item)
        icon = item.reserved_by ? "🔒" : "🎁"
        text = "#{icon} #{item.title}\n"

        if item.reserved_by
          user = User.find_by(telegram_id: item.reserved_by)
          text << "🤵 @#{user&.username || user&.first_name}\n"
        end

        text << "💬 #{item.description}\n" if item.description.present?
        text << "🔗 #{item.url}\n" if item.url.present?
        text << "💵 #{item.price}₽\n" if item.price.present?

        text
      end

      def build_item_buttons(context, item, is_owner)
        buttons = []
        row = []

        # Reserve / unreserve button
        if item.reserved_by.nil?
          row << context.inline_btn("🟩 Забронировать", "toggle_reserve:#{item.id}")
        elsif item.reserved_by == context.user.telegram_id
          row << context.inline_btn("🟨 Снять резерв", "toggle_reserve:#{item.id}")
        else
          row << context.inline_btn("🔴 Занято", "noop")
        end

        buttons << row

        # Owner-only buttons
        if is_owner
          buttons << [
            context.inline_btn("✏️ Редактировать", "edit_item:#{item.id}"),
            context.inline_btn("🗑 Удалить", "delete_item:#{item.id}")
          ]
        end

        buttons
      end

      def build_list_management_buttons(context, wishlist, is_owner)
        buttons = []

        if is_owner
          buttons << [context.inline_btn("➕ Добавить подарок", "add_item:#{wishlist.id}")]
          buttons << [context.inline_btn("✏️ Переименовать список", "rename_list:#{wishlist.id}")]
          buttons << [context.inline_btn("🗑 Удалить список", "delete_list:#{wishlist.id}")]
        end

        buttons << [context.inline_btn("📋 Мои списки", "show_lists")]
        buttons
      end

      # Helper methods for item reservation

      def reserve_item(context, item)
        item.update!(reserved_by: context.user.telegram_id)
        notify_viewers(item.wishlist, "🔒 «#{item.title}» забронирован пользователем @#{context.user.username}")
        context.send_text("Вы забронировали «#{item.title}»")
        open_list(context, item.wishlist.id)
      end

      def unreserve_item(context, item)
        item.update!(reserved_by: nil)
        notify_viewers(item.wishlist, "🔓 Резерв снят с «#{item.title}»")
        context.send_text("Вы сняли резерв с «#{item.title}»")
        open_list(context, item.wishlist.id)
      end

      # Notification and viewer management

      def notify_viewers(wishlist, message)
        return if wishlist.list_viewers.empty?

        bot = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))
        wishlist.list_viewers.includes(:user).distinct.each do |viewer|
          next unless viewer.user&.telegram_id.present?

          send_notification(bot, viewer.user.telegram_id, message)
        end
      end

      def send_notification(bot, chat_id, message)
        bot.api.send_message(chat_id: chat_id, text: message)
      rescue Telegram::Bot::Exceptions::ResponseError => e
        Rails.logger.error("Failed to send telegram notification: #{e.message}")
      end

      def add_user_to_list_viewers(user, wishlist)
        return if wishlist.has_viewer?(user)

        wishlist.list_viewers.create!(user: user)
      end
    end
  end
end
