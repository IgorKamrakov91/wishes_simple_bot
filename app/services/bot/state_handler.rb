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
    rescue ActiveRecord::RecordNotFound
      # The list or gift was deleted while the user was typing
      user.clear_state!
      keyboard = build_keyboard([ [ inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ] ])
      context.send_text(I18n.t("bot.messages.input_target_gone"), keyboard)
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

    # The gift stays a draft in the payload until its link is given or
    # skipped: cancelling on the way publishes nothing.
    def create_item
      wishlist = user.wishlists.find(user.bot_payload["wishlist_id"])
      return context.send_text(I18n.t("bot.messages.enter_item_name")) if text.blank?

      draft_id = SecureRandom.hex(4)
      user.update!(bot_state: "adding_item_url",
                   bot_payload: { "wishlist_id" => wishlist.id, "title" => text, "draft_id" => draft_id })

      keyboard = build_keyboard([
        [ inline_btn(I18n.t("bot.buttons.skip_url"), "skip_item_url:#{draft_id}", style: "primary") ],
        [ inline_btn(I18n.t("bot.buttons.cancel"), "open_list:#{wishlist.id}") ]
      ])
      context.render(I18n.t("bot.messages.enter_item_url", title: escape_html(text), list: escape_html(wishlist.title)), keyboard)
    end

    def create_item_url
      url = optional_text_value(text)
      payload = user.bot_payload

      wishlist_id =
        if payload.key?("item_id")
          # Started before drafts: the gift is already saved
          item = user.items.find(payload["item_id"])
          item.update!(url: url)
          item.wishlist_id
        else
          wishlist = user.wishlists.find(payload["wishlist_id"])
          wishlist.items.create!(title: payload["title"], url: url)
          wishlist.id
        end

      user.clear_state!
      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [ [ inline_btn(I18n.t("bot.buttons.add_more"), "add_item:#{wishlist_id}") ], [ inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{wishlist_id}") ] ])
      context.render(I18n.t("bot.messages.item_added"), keyboard)
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
