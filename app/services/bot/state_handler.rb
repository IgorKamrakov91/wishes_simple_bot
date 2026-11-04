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
    rescue ActiveRecord::RecordInvalid
      context.send_text(I18n.t("bot.messages.error"))
    end

    private

    def create_list
      wishlist = user.wishlists.create!(title: text)
      user.clear_state!
      Callbacks::WishlistHandler.new(context).open_list(wishlist.id)
    end

    def rename_list
      wishlist_id = user.bot_payload["wishlist_id"]
      wishlist = user.wishlists.find(wishlist_id)
      wishlist.update!(title: text)
      user.clear_state!
      Callbacks::WishlistHandler.new(context).open_list(wishlist.id)
    end

    def create_item
      wishlist_id = user.bot_payload["wishlist_id"]
      wishlist = user.wishlists.find(wishlist_id)
      item = wishlist.items.create!(title: text)
      user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => wishlist.id })
      context.send_text(I18n.t("bot.messages.enter_item_url"))
    end

    def create_item_url
      item = user.items.find(user.bot_payload["item_id"])
      wishlist_id = item.wishlist_id
      url = optional_text_value(text)
      item.update!(url: url)
      user.clear_state!
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [ [ inline_btn(I18n.t("bot.buttons.add_more"), "add_item:#{wishlist_id}") ], [ inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{wishlist_id}") ] ])
      context.send_text(I18n.t("bot.messages.item_added"), keyboard)
    end

    def update_item_field
      item = user.items.find(user.bot_payload["item_id"])
      field = user.bot_payload["field"]
      return context.send_text(I18n.t("bot.messages.error")) unless Item::EDITABLE_FIELDS.include?(field)

      value = item_field_value(field, text)
      item.update!(field => value)
      user.clear_state!
      Callbacks::ItemHandler.new(context).show_item(item.id)
    end

    def item_field_value(field, value)
      normalized_value = optional_text_value(value)
      return nil if normalized_value.nil?

      # "6 000,50" -> "6000.50"
      field == "price" ? normalized_value.gsub(/[[:space:]]/, "").tr(",", ".") : normalized_value
    end

    def optional_text_value(value)
      normalized_value = value.to_s.strip
      normalized_value.presence unless normalized_value == "-"
    end
  end
end
