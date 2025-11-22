module Bot
  class Callbacks
    extend Bot::Helpers

    class << self
      def handle(bot, callback)
        data = callback.data
        user = User.find_or_create_from_telegram(callback.from.to_h.symbolize_keys)
        chat_id = callback.message&.chat&.id || callback.from.id

        case data
        when "show_lists"
          show_lists(bot, user, chat_id)
        when "new_list"
          create_list_prompt(bot, user, chat_id)
        when /^rename_list:(\d+)$/
          rename_list_prompt(bot, user, chat_id, $1.to_i)
        when /^delete_list:(\d+)$/
          delete_list(bot, user, chat_id, $1.to_i)
        when /^add_item:(\d+)$/
          wishlist_id = $1.to_i
          add_item_prompt(bot, user, chat_id, wishlist_id)
        when /^edit_item:(\d+)$/
          edit_item_menu(bot, user, chat_id, $1.to_i)
        when /^edit_item_field:(.+):(\d+)$/
          field = $1
          item_id = $2.to_i
          edit_item_field_prompt(bot, user, chat_id, item_id, field)
        when /^toggle_reserve:(\d+)$/
          toggle_reserve(bot, user, chat_id, $1.to_i)
        when /^delete_item:(\d+)$/
          delete_item(bot, user, chat_id, $1.to_i)
        when /^open_shared_list:(\d+)$/
          open_shared_list(bot, user, chat_id, $1.to_i)
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
          [inline_btn(list.title, "open_list:#{list.id}")]
        end

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)

        send_text(bot, chat_id, "Мои списки:", keyboard)
      end

      def create_list_prompt(bot, user, chat_id)
        user.start_creating_list!
        send_text(bot, chat_id, "Введите название списка:")
      end

      def open_list(bot, user, chat_id, id)
        wishlist = Wishlist.find(id)
        is_owner = (wishlist.user_id == user.id)

        # register opener as a viewer
        add_user_to_list_viewers(user, wishlist) unless is_owner

        if wishlist.items.empty?
          text = "Список «#{wishlist.title}» пуст.\nДобавьте подарок:"
        else
          text = "🎉 Список «#{wishlist.title}»:\n\n"

          wishlist.items.each do |item|
            mark = item.reserved_by ? "🔒 (#{item.reserved_by})" : "🎁"
            text << "#{mark} #{item.title}\n"
          end
        end

        buttons = []
        buttons << [inline_btn("Добавить подарок", "add_item:#{wishlist.id}")] if is_owner
        buttons << [inline_btn("Переименовать список", "rename_list:#{wishlist.id}")] if is_owner
        buttons << [inline_btn("Удалить список", "delete_list:#{wishlist.id}")] if is_owner
        wishlist.items.each do |i|
          # Only an owner can edit/delete; everyone else only can reserve
          row = []
          row << inline_btn("🔒/🔓 #{i.title}", "toggle_reserve:#{i.id}")
          if is_owner
            row << inline_btn("✏️", "edit_item:#{i.id}")
            row << inline_btn("🗑", "delete_item:#{i.id}")
          end
          buttons << row
        end
        buttons << [inline_btn("Мои списки", "show_lists")]
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)

        send_text(bot, chat_id, text, keyboard)
      end

      def rename_list_prompt(bot, user, chat_id, wishlist_id)
        user.start_renaming_list!(wishlist_id: wishlist_id)
        send_text(bot, chat_id, "Введите новое название списка:")
      end

      def delete_list(bot, user, chat_id, wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)
        wishlist.destroy!

        send_text(bot, chat_id, "Список удален!")
        show_lists(bot, user, chat_id)
      end

      def add_item_prompt(bot, user, chat_id, wishlist_id)
        user.start_adding_item!(wishlist_id: wishlist_id)
        send_text(bot, chat_id, "Введите название подарка:")
      end

      def edit_item_menu(bot, user, chat_id, item_id)
        item = Item.find(item_id)

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [inline_btn("Название", "edit_item_field:title:#{item.id}")],
            [inline_btn("Описание", "edit_item_field:description:#{item.id}")],
            [inline_btn("URL", "edit_item_field:url:#{item.id}")],
            [inline_btn("Цена", "edit_item_field:price:#{item.id}")]
          ]
        )

        send_text(bot, chat_id, "Что хотите изменить для «#{item.title}»?", keyboard)
      end

      def edit_item_field_prompt(bot, user, chat_id, item_id, field)
        user.update!(
          bot_state: "editing_item",
          bot_payload: { item_id: item_id, field: field }
        )

        send_text(bot, chat_id, "Введите новое значение поля «#{field}»:")
      end

      def item_buttons(item)
        [
          inline_btn("✏️ #{item.title}", "edit_item:#{item.id}"),
          inline_btn(item.reserved_by ? "🔓 снять резерв" : "🔒 забронировать", "toggle_reserve:#{item.id}"),
          inline_btn("🗑 удалить", "delete_item:#{item.id}")
        ]
      end

      def toggle_reserve(bot, user, chat_id, item_id)
        item = Item.find(item_id)

        if item.reserved_by && item.reserved_by != user.telegram_id
          send_text(bot, chat_id, "Этот подарок забронирован другим пользователем.")
          return
        end
        if item.reserved_by == user.telegram_id
          item.update!(reserved_by: nil)

          notify_viewers(item.wishlist, "🔓 Резерв снят с «#{item.title}»")
          send_text(bot, chat_id, "Вы сняли резерв с «#{item.title}»")
        else
          item.update!(reserved_by: user.telegram_id)

          notify_viewers(item.wishlist, "🔒 «#{item.title}» забронирован пользователем @#{user.username}")
          send_text(bot, chat_id, "Вы забронировали «#{item.title}»")
        end
      end

      def delete_item(bot, user, chat_id, item_id)
        item = Item.find(item_id)
        wishlist = item.wishlist

        item.destroy!

        notify_viewers(wishlist, "🗑 «#{item.title}» удален")
        send_text(bot, chat_id, "Подарок удален!")

        open_list(bot, user, chat_id, wishlist.id)
      end

      def open_shared_list(bot, user, chat_id, wishlist_id)
        wishlist = Wishlist.find(wishlist_id)
        wishlist.list_viewers.find_or_create_by!(user: user)

        open_list(bot, user, chat_id, wishlist_id)
      end

      def notify_viewers(wishlist, message)
        return if wishlist.list_viewers.empty?

        bot = Telegram::Bot::Client.new("8179126467:AAFWyk5lQ9cOZSAHvyaNGfBppR6udi2ohx8")
        unique_viewers = wishlist.list_viewers.includes(:user).distinct
        unique_viewers.each do |viewer|
          next unless viewer.user&.telegram_id.present?

          begin
            bot.api.send_message(
              chat_id: viewer.user.telegram_id,
              text: message
            )
          rescue Telegram::Bot::Exceptions::ResponseError => e
            Rails.logger.error("Failed to send telegram notification: #{e.message}")
          end
        end
      end

      def add_user_to_list_viewers(user, wishlist)
        return if wishlist.has_viewer?(user)

        wishlist.list_viewers.create!(user: user, last_viewed_at: Time.now)
      end
    end
  end
end
