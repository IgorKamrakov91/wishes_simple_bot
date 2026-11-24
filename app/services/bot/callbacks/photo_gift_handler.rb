module Bot
  module Callbacks
    class PhotoGiftHandler < BaseHandler
      FIELD_KEYS = Presenters::PhotoGiftPresenter::FIELD_KEYS
      LISTS_PER_PAGE = 5
      CALLBACK_PATTERN = /\A(?:pg:[amstpdulxcr]:\d+:\d+|pgl:\d+:\d+:\d+|pgw:\d+:\d+:\d+|pgb:\d+|ip:\d+)\z/

      def show(id)
        draft = owned(id)
        clear_input_for(draft) unless draft.editable?
        UpdateDelivery.record_result("photo_gift", draft.id)
        presenter = Presenters::PhotoGiftPresenter.new(draft, user, context)
        context.render(presenter.text, presenter.keyboard)
      end

      def action(action, id, version)
        draft = owned(id)
        return show_saved(draft) if draft.status == "saved"
        return outdated(draft) unless draft.editable? && draft.version == version

        case action
        when "a" then draft.consent!(expected_version: version)
        when "m" then draft.manual!(expected_version: version)
        when "r" then draft.retry_recognition!(expected_version: version)
        when "x" then draft.remove_photo!(expected_version: version)
        when "l" then return lists(id, version)
        when "c"
          draft.cancel!(expected_version: version)
          clear_input_for(draft)
          return context.render(I18n.t("bot.commands.cancelled"))
        when "s" then return save(draft)
        else
          return edit(draft, FIELD_KEYS.fetch(action))
        end
        show(draft.id)
      end

      def lists(id, version, page = 0)
        draft = owned(id)
        return outdated(draft) unless draft.editable? && draft.version == version

        scope = user.wishlists.order(updated_at: :desc, id: :desc)
        page = page.clamp(0, [ (scope.count - 1) / LISTS_PER_PAGE, 0 ].max)
        rows = scope.offset(page * LISTS_PER_PAGE).limit(LISTS_PER_PAGE).map do |list|
          [ inline_btn(list.title.truncate(50), "pgw:#{id}:#{version}:#{list.id}") ]
        end
        pager = []
        pager << inline_btn(I18n.t("bot.buttons.prev_page"), "pgl:#{id}:#{version}:#{page - 1}") if page.positive?
        pager << inline_btn(I18n.t("bot.buttons.next_page"), "pgl:#{id}:#{version}:#{page + 1}") if scope.count > (page + 1) * LISTS_PER_PAGE
        rows << pager if pager.any?
        rows << [ inline_btn(I18n.t("bot.photo_gift.new_list", list: I18n.t("bot.photo_gift.default_list")), "pgw:#{id}:#{version}:0") ]
        # Returning to review is separate from selecting a list.
        rows << [ inline_btn(I18n.t("bot.buttons.back"), "pgb:#{id}") ]
        context.render(I18n.t("bot.photo_gift.choose_list"), build_keyboard(rows))
      end

      def select_list(id, version, list_id)
        draft = owned(id)
        draft.select_list!(list_id, expected_version: version)
        show(draft.id)
      end

      def field_input
        payload = user.bot_payload || {}
        draft = owned(payload.fetch("photo_gift_draft_id"))
        field = payload.fetch("field")
        value = context.text.presence
        return context.send_text(I18n.t("bot.input_errors.text_only")) if context.non_text_message?

        value = nil if value == "-" && Item::OPTIONAL_FIELDS.include?(field)
        if field == "price" && value
          value = value.gsub(/[[:space:]]/, "").sub(StateHandler::CURRENCY_AFFIX, "").tr(",", ".")
        elsif field == "url" && value && StateHandler::BARE_LINK.match?(value)
          value = "https://#{value}"
        end
        changed = draft.update_field!(field, value, expected_version: payload.fetch("version"))
        if changed
          user.update!(bot_state: "photo_gift", bot_payload: { "photo_gift_draft_id" => draft.id })
        end
        show(draft.id)
      rescue ActiveRecord::RecordInvalid => e
        error = e.record.errors.first
        message = I18n.t("bot.input_errors.#{error.attribute}.#{error.type}", count: error.options[:count],
          limit: error.options[:count], default: I18n.t("bot.input_errors.invalid"))
        context.send_text(message, InputPrompt.new(context).prompt&.last)
      end

      def input_prompt
        draft = owned(user.bot_payload.fetch("photo_gift_draft_id"))
        field = user.bot_payload.fetch("field")
        [ I18n.t("bot.photo_gift.enter_field", field: I18n.t("bot.fields.#{field}")),
          build_keyboard([ [ inline_btn(I18n.t("bot.buttons.back"), "pgb:#{draft.id}") ] ]) ]
      end

      def back(id)
        draft = owned(id)
        if user.bot_state == "editing_photo_gift" && user.bot_payload&.dig("photo_gift_draft_id") == draft.id
          user.update!(bot_state: "photo_gift", bot_payload: { "photo_gift_draft_id" => draft.id })
        end
        show(id)
      end

      private

      def owned(id)
        raise ActiveRecord::RecordNotFound unless PhotoGiftDraft.enabled?

        user.photo_gift_drafts.find(id)
      rescue ActiveRecord::RecordNotFound
        if user.bot_payload&.dig("photo_gift_draft_id") == id.to_i
          user.update!(bot_state: nil, bot_payload: nil)
        end
        raise
      end

      def edit(draft, field)
        user.with_lock do
          if user.bot_state.present? && user.bot_payload&.dig("photo_gift_draft_id") != draft.id
            context.notice = I18n.t("bot.photo_gift.finish_input")
            return InputPrompt.new(context).render
          end
          return outdated(draft) unless draft.manual!(expected_version: draft.version)

          user.update!(bot_state: "editing_photo_gift", bot_payload: {
            "photo_gift_draft_id" => draft.id, "version" => draft.version, "field" => field
          })
        end
        UpdateDelivery.record_result("photo_gift", draft.id)
        InputPrompt.new(context).render
      end

      def save(draft)
        return edit(draft, "title") if draft.result["title"].blank?

        first = user.onboarding?
        status, item = draft.save_gift!(expected_version: draft.version)
        return show_saved(draft, first: first) if %i[saved already].include?(status) && item

        if status == :photo_pending
          context.notice = I18n.t(draft.media_status == "failed" ? "bot.photo_gift.media_failed" : "bot.photo_gift.preparing")
        else
          context.notice = I18n.t("bot.messages.button_outdated")
        end
        show(draft.id)
      rescue ActiveRecord::RecordNotFound
        context.notice = I18n.t("bot.photo_gift.missing_list")
        lists(draft.id, draft.reload.version)
      end

      def show_saved(draft, first: false)
        item = user.items.find(draft.item_id)
        UpdateDelivery.record_result(first ? "first_gift_added" : "gift_added", item.id)
        if first
          context.render(*Presenters::FirstGiftPresenter.new(item, context).screen)
        else
          ItemHandler.new(context).show_item(item.id)
        end
      end

      def clear_input_for(draft)
        user.update!(bot_state: nil, bot_payload: nil) if user.bot_payload&.dig("photo_gift_draft_id") == draft.id
      end

      def outdated(draft)
        context.notice = I18n.t("bot.messages.button_outdated")
        show(draft.id)
      end
    end
  end
end
