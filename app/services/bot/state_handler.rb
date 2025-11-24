# frozen_string_literal: true

module Bot
  class StateHandler
    include Helpers
    include ActiveSupport::Delegation

    attr_reader :context
    delegate :bot, :user, :chat_id, :text, to: :context

    def initialize(context)
      @context = context
    end

    def handle
      case user.bot_state
      when "creating_list"
        create_list
      when "renaming_list"
        rename_list
      when "adding_item"
        create_item
      when "adding_item_url"
        create_item_url
      when "editing_item"
        update_item_field
      end
    end

    private

    def create_list
      wishlist = user.wishlists.create!(title: text)
      user.clear_state!
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [ [ inline_btn("Добавить подарок", "add_item:#{wishlist.id}") ], [ inline_btn("Мои списки", "show_lists") ] ])
      context.send_text("Список #{wishlist.title} создан!", keyboard)
    end

    def rename_list
      wishlist_id = user.bot_payload["wishlist_id"]
      wishlist = user.wishlists.find(wishlist_id)
      wishlist.update!(title: text)
      user.clear_state!
      context.send_text("Название списка изменено!")
    end

    def create_item
      wishlist_id = user.bot_payload["wishlist_id"]
      wishlist = user.wishlists.find(wishlist_id)
      item = wishlist.items.create!(title: text)
      user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => wishlist.id })
      context.send_text("Введите URL для подарка (или '-' если пропустить):")
    end

    def create_item_url
      item = Item.find(user.bot_payload["item_id"])
      wishlist_id = user.bot_payload["wishlist_id"]
      url = text == "-" ? nil : text
      item.update!(url: url)
      user.clear_state!
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [ [ inline_btn("Добавить ещё", "add_item:#{wishlist_id}") ], [ inline_btn("Открыть список", "open_list:#{wishlist_id}") ] ])
      context.send_text("Подарок успешно добавлен!", keyboard)
    end

    def update_item_field
      item = Item.find(user.bot_payload["item_id"])
      field = user.bot_payload["field"]
      value = (field == "price") ? text.gsub(",", ".").to_f : text
      item.update!(field => value)
      user.clear_state!
      wishlist_id = item.wishlist_id
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [ [ inline_btn("Редактировать ещё", "edit_item:#{item.id}") ], [ inline_btn("Открыть список", "open_list:#{wishlist_id}") ] ])
      context.send_text("Поле «#{field}» обновлено!", keyboard)
    end
  end
end
