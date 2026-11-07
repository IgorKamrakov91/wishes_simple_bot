# frozen_string_literal: true

module Bot
  class StateHandler
    include Helpers
    include ActiveSupport::Delegation

    # "ozon.ru/t/abc" without a scheme is still clearly a link
    BARE_LINK = %r{\A[\w-]+(\.[\w-]+)+(/\S*)?\z}
    CURRENCY_SUFFIX = /(₽|руб\.?|р\.?)\z/i

    attr_reader :context
    delegate :bot, :user, :chat_id, :text, to: :context

    def initialize(context)
      @context = context
    end

    # Answers the pending input with the text the user sent
    def handle
      return if replayed_list_name?

      # A photo or sticker has no text to use as the value
      return reply_with_problem(I18n.t("bot.input_errors.text_only")) if context.try(:non_text_message?)

      handling_input_errors do
        case user.bot_state
        when "creating_list"
          create_list
        when "renaming_list"
          rename_list
        when "adding_item", "adding_item_title"
          create_item
        when "adding_item_url"
          save_item(item_field_value("url", text))
        when "editing_item"
          update_item_field
        end
      end
    end

    # "Save without a link" on the link step
    def save_item_without_link
      handling_input_errors { save_item(nil) }
    end

    private

    def handling_input_errors
      yield
    rescue ActiveRecord::RecordInvalid => e
      # The input stays active, so the user can just send a fixed value
      reply_with_problem(error_message(e.record))
    rescue ActiveRecord::RecordNotFound
      reply_with_missing_target
    end

    # Like gifts: the state is rechecked under a lock on the user, so two
    # deliveries of the same answer can't create two lists
    def create_list
      wishlist = nil
      user.with_lock do
        next unless user.bot_state == "creating_list" && !replayed_list_name?

        wishlist = user.wishlists.create!(title: text)
        attributes = { bot_state: "adding_item", bot_payload: { "wishlist_id" => wishlist.id, "first_item" => true } }
        attributes[:last_list_creation_message_id] = source_message_id if source_message_id
        user.update!(attributes)
      end
      if wishlist
        UpdateDelivery.record_result("list_created", wishlist.id)
        InputPrompt.new(context).render
      end
    end

    def rename_list
      wishlist = nil
      user.with_lock do
        next unless user.bot_state == "renaming_list" && !replayed_list_name?

        wishlist = user.wishlists.find(user.bot_payload["wishlist_id"])
        wishlist.update!(title: text)
        user.clear_state!
      end
      if wishlist
        UpdateDelivery.record_result("list_renamed", wishlist.id)
        Callbacks::WishlistHandler.new(context).open_list(wishlist.id)
      end
    end

    # The gift stays a draft until its name and optional link are settled.
    # Cancelling on the way publishes nothing.
    def create_item
      prompt = nil
      item = nil
      user.with_lock do
        next unless %w[adding_item adding_item_title].include?(user.bot_state) && !replayed_list_name?

        wishlist = user.wishlists.find(user.bot_payload["wishlist_id"])
        if link_input?(text)
          prompt = draft_with_url(wishlist, item_field_value("url", text))
        elsif user.bot_state == "adding_item_title"
          item = wishlist.items.create!(title: text, url: user.bot_payload["url"])
          user.clear_state!
        else
          prompt = draft_with_title(wishlist)
        end
      end

      context.render(*prompt) if prompt
      show_saved_item(item) if item
    end

    def draft_with_url(wishlist, url)
      # This name is only for validating the URL with the model's contract;
      # no gift is published until the user gives it a name.
      Item.new(wishlist: wishlist, title: "Draft", url: url).validate!
      user.update!(bot_state: "adding_item_title",
                   bot_payload: { "wishlist_id" => wishlist.id, "url" => url })
      InputPrompt.new(context).prompt
    end

    def draft_with_title(wishlist)
      # Check the name now rather than after the link step.
      wishlist.items.build(title: text).validate!

      # The letter prefix keeps the id a string: routing turns all-digit captures into numbers
      draft_id = "d#{SecureRandom.hex(4)}"
      user.update!(bot_state: "adding_item_url",
                   bot_payload: { "wishlist_id" => wishlist.id, "title" => text, "draft_id" => draft_id })
      InputPrompt.new(context).prompt
    end

    # Saving the gift and ending the input happen together under a lock on
    # the user, so two quick answers can't save the draft twice
    def save_item(url)
      item = nil

      user.with_lock do
        payload = user.bot_payload
        next unless user.bot_state == "adding_item_url" && payload && !replayed_list_name?

        item =
          if payload.key?("item_id")
            # Started before drafts: the gift is already saved
            item = user.items.find(payload["item_id"])
            item.update!(url: url)
            item
          else
            wishlist = user.wishlists.find(payload["wishlist_id"])
            wishlist.items.create!(title: payload["title"], url: url)
          end

        user.clear_state!
      end
      show_saved_item(item) if item
    end

    def link_input?(value)
      value = value.to_s.strip
      return true if value.match?(%r{\Ahttps?://}i)
      return false unless user.bot_state == "adding_item"

      # Inspect the original input before URL-field normalization turns a
      # dotted name such as Lego.Technic into an https URL. Bare links need
      # a path, and are accepted only before we explicitly ask for a name.
      value.match?(%r{\A[a-z][a-z0-9+.-]*://}i) || (BARE_LINK.match?(value) && value.include?("/"))
    end

    def show_saved_item(item)
      UpdateDelivery.record_result("gift_added", item.id)
      details = []
      details << inline_btn(I18n.t("bot.buttons.add_price"), "edit_item_field:price:#{item.id}") unless item.price
      details << inline_btn(I18n.t("bot.buttons.add_description"), "edit_item_field:description:#{item.id}") if item.description.blank?
      rows = []
      rows << details if details.any?
      rows << [ inline_btn(I18n.t("bot.buttons.open_item"), "open_item:#{item.id}") ]
      rows << [ inline_btn(I18n.t("bot.buttons.add_more"), "add_item:#{item.wishlist_id}") ]
      rows << [ inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{item.wishlist_id}") ]
      message = I18n.t("bot.messages.item_added", title: escape_html(item.title.to_s.truncate(100)),
                       list: escape_html(item.wishlist.title.to_s.truncate(100)))
      context.render(message, build_keyboard(rows))
    end

    def update_item_field
      item = nil
      user.with_lock do
        # Another delivery or cancellation may already have ended this edit.
        next unless user.bot_state == "editing_item" && !replayed_list_name?

        field = user.bot_payload["field"]
        return context.send_text(I18n.t("bot.messages.error")) unless Item::EDITABLE_FIELDS.include?(field)

        item = user.items.find(user.bot_payload["item_id"])
        item.update!(field => item_field_value(field, text))
        user.clear_state!
      end
      if item
        UpdateDelivery.record_result("gift_updated", item.id)
        Callbacks::ItemHandler.new(context).show_item(item.id)
      end
    end

    def item_field_value(field, value)
      normalized_value = optional_text_value(value)
      return nil if normalized_value.nil?

      case field
      when "price"
        # "6 000,50 ₽" -> "6000.50"
        normalized_value.gsub(/[[:space:]]/, "").sub(CURRENCY_SUFFIX, "").tr(",", ".")
      when "url"
        BARE_LINK.match?(normalized_value) ? "https://#{normalized_value}" : normalized_value
      else
        normalized_value
      end
    end

    def optional_text_value(value)
      normalized_value = value.to_s.strip
      normalized_value.presence unless normalized_value == "-"
    end

    # Explains the first problem with the value in words
    def error_message(record)
      error = record.errors.first
      return I18n.t("bot.messages.error") unless error

      I18n.t("bot.input_errors.#{error.attribute}.#{error.type}",
             count: error.options[:count],
             limit: (format_price(error.options[:count]) if error.attribute == :price && error.type == :less_than),
             default: I18n.t("bot.input_errors.invalid"))
    end

    def reply_with_problem(message)
      context.send_text(message, InputPrompt.new(context).prompt&.last)
    rescue ActiveRecord::RecordNotFound
      reply_with_missing_target
    end

    def reply_with_missing_target
      # The list or gift was deleted while the user was typing.
      user.clear_state!
      keyboard = build_keyboard([ [ inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ] ])
      context.send_text(I18n.t("bot.messages.input_target_gone"), keyboard)
    end

    def source_message_id
      source = context.try(:source)
      source.message_id if source.is_a?(Telegram::Bot::Types::Message)
    end

    # A list name must never be consumed as a gift name by a later delivery,
    # even after cancellation or another draft. Recheck under each write lock.
    def replayed_list_name?
      source_message_id && user.last_list_creation_message_id && source_message_id <= user.last_list_creation_message_id
    end
  end
end
