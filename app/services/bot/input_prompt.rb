# frozen_string_literal: true

module Bot
  # The question the bot asks for the pending input, built from the user's
  # state. The same text and buttons show when the input starts and when the
  # user comes back to it from help or settings.
  class InputPrompt
    include Helpers

    attr_reader :context

    def initialize(context)
      @context = context
    end

    def active?
      user.bot_state.present?
    end

    # A newcomer's first gift already has a link or a name typed. Going back
    # to the menu keeps it, so the first result isn't lost on the way.
    def onboarding_draft?
      %w[adding_item_title adding_item_url photo_gift editing_photo_gift].include?(user.bot_state) && user.onboarding?
    end

    # Only the list and prompt marker are present before any gift was typed.
    # Recheck this under the user lock before an AI choice finishes the input.
    def empty_item_input?(wishlist_id)
      user.bot_state == "adding_item" && payload[:wishlist_id] == wishlist_id &&
        payload.except(:wishlist_id, :first_item).empty?
    end

    def render
      if user.bot_state == "photo_gift"
        return Callbacks::PhotoGiftHandler.new(context).show(payload[:photo_gift_draft_id])
      end

      text, keyboard = prompt
      context.render(text, keyboard)
    end

    # Buttons for screens that keep the input open
    def resume_rows
      return [] unless active?

      [ [
        context.inline_btn(I18n.t("bot.buttons.resume_input"), "resume_input"),
        context.inline_btn(I18n.t("bot.buttons.cancel_input"), "cancel_input")
      ] ]
    end

    def with_input_note(text)
      active? ? "#{I18n.t('bot.commands.input_active')}\n\n#{text}" : text
    end

    # [text, keyboard] for the current state, nil when there is no input
    def prompt
      case user.bot_state
      when "photo_gift"
        draft = user.photo_gift_drafts.find(payload[:photo_gift_draft_id])
        presenter = Presenters::PhotoGiftPresenter.new(draft, user, context)
        [ presenter.text, presenter.keyboard ]
      when "editing_photo_gift"
        Callbacks::PhotoGiftHandler.new(context).input_prompt
      when "creating_list"
        rows = ListPresets.ordered.map { |key| [ context.inline_btn(ListPresets.label(key), "quick_list:#{key}") ] }
        rows << [ context.inline_btn(I18n.t("bot.buttons.cancel"), "show_lists") ]
        [ I18n.t("bot.messages.enter_list_name"), context.build_keyboard(rows) ]
      when "renaming_list"
        text = [ I18n.t("bot.messages.enter_new_list_name"), list_context ].join("\n")
        [ text, cancel_keyboard("list_settings:#{payload[:wishlist_id]}") ]
      when "adding_item"
        if payload[:first_item]
          text = I18n.t("bot.messages.first_item_prompt", list: list_title)
          rows = []
          if user.onboarding? && GiftSuggestion.enabled?
            rows << [ context.inline_btn(I18n.t("bot.gift_ideas.onboarding_button"), "gift_ideas:#{payload[:wishlist_id]}") ]
            recent = GiftSuggestion.latest_ready_for(user, user.wishlists.find(payload[:wishlist_id]))
            rows << [ context.inline_btn(I18n.t("bot.gift_ideas.recent"), "show_gift_ideas:#{recent.id}") ] if recent
          end
          rows << [ context.inline_btn(I18n.t("bot.messages.add_item_later"), "open_list:#{payload[:wishlist_id]}") ]
          keyboard = context.build_keyboard(rows)
          [ text, keyboard ]
        else
          [ [ list_context, I18n.t("bot.messages.enter_item_name") ].join("\n"), cancel_keyboard("open_list:#{payload[:wishlist_id]}") ]
        end
      when "adding_item_title"
        [ I18n.t("bot.messages.name_linked_item", list: list_title), cancel_keyboard("open_list:#{payload[:wishlist_id]}") ]
      when "adding_item_url"
        item_url_prompt
      when "editing_item"
        edit_prompt
      end
    end

    private

    def user
      context.user
    end

    def payload
      (user.bot_payload || {}).with_indifferent_access
    end

    def list_title
      escape_html(user.wishlists.find(payload[:wishlist_id]).title.to_s.truncate(100))
    end

    def list_context
      I18n.t("bot.messages.list_context", list: list_title)
    end

    def item_url_prompt
      skip = [ "skip_item_url", payload[:draft_id] ].compact.join(":")
      keyboard = context.build_keyboard([
        [ context.inline_btn(I18n.t("bot.buttons.skip_url"), skip, style: "primary") ],
        [ context.inline_btn(I18n.t("bot.buttons.cancel"), "open_list:#{payload[:wishlist_id]}") ]
      ])
      # Drafts from before draft ids kept a saved gift instead of a title
      title = payload[:title] || user.items.find_by(id: payload[:item_id])&.title
      [ I18n.t("bot.messages.enter_item_url", title: escape_html(title.to_s), list: list_title), keyboard ]
    end

    def edit_prompt
      item = user.items.find(payload[:item_id])
      field = payload[:field]
      current = item.public_send(field)

      rows = []
      if current.present? && Item::OPTIONAL_FIELDS.include?(field)
        label = I18n.t("bot.buttons.clear_field", field: I18n.t("bot.messages.clear_fields.#{field}"))
        rows << [ context.inline_btn(label, "clear_item_field:#{field}:#{item.id}") ]
      end
      rows << [ context.inline_btn(I18n.t("bot.buttons.cancel"), "open_item:#{item.id}") ]

      [ edit_prompt_text(item, field, current), context.build_keyboard(rows) ]
    end

    def edit_prompt_text(item, field, current)
      lines = [ I18n.t("bot.messages.enter_new_value", field: I18n.t("bot.fields.#{field}")) ]
      lines << I18n.t("bot.messages.item_context", title: escape_html(item.title.to_s.truncate(100)),
                     list: escape_html(item.wishlist.title.to_s.truncate(100)))
      hint = I18n.t("bot.input_hints.#{field}", default: nil)
      lines << "<i>#{hint}</i>" if hint
      if current.present?
        shown = field == "price" ? format_price(current) : current.to_s.truncate(200)
        lines << "\n#{I18n.t('bot.messages.current_value')}: #{escape_html(shown)}"
      end
      lines.join("\n")
    end

    def cancel_keyboard(callback_data)
      context.build_keyboard([ [ context.inline_btn(I18n.t("bot.buttons.cancel"), callback_data) ] ])
    end
  end
end
