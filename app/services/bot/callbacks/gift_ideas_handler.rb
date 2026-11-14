# frozen_string_literal: true

module Bot
  module Callbacks
    class GiftIdeasHandler < BaseHandler
      def request_ideas(wishlist_id)
        wishlist = user.wishlists.find(wishlist_id)
        return disabled unless GiftSuggestion.enabled?

        result = GiftSuggestion.request_for!(user, wishlist)
        if %i[created active].include?(result.status)
          UpdateDelivery.record_result("gift_ideas", result.suggestion.id)
        end
        context.notice = request_notice(result.status, wishlist)
      end

      def show_ideas(suggestion_id)
        suggestion = owned_suggestion(suggestion_id)
        UpdateDelivery.record_result("gift_ideas", suggestion.id)
        presenter = Presenters::GiftIdeasPresenter.new(suggestion)
        prompt = InputPrompt.new(context)
        rows = presenter.keyboard.inline_keyboard + prompt.resume_rows
        context.render(prompt.with_input_note(presenter.text), build_keyboard(rows))
      end

      def add_idea(suggestion_id, index)
        suggestion = owned_suggestion(suggestion_id)
        return disabled unless GiftSuggestion.enabled?

        user.with_lock do
          # The callback keeps the draft; don't publish another gift alongside it.
          if user.bot_state.present?
            context.notice = I18n.t("bot.gift_ideas.finish_input")
            return InputPrompt.new(context).render
          end
          return show_ideas(suggestion.id) if suggestion.created_at < GiftSuggestion::OPEN_FOR.ago

          status, item = suggestion.add_idea!(user, index)
          if %i[added already].include?(status)
            UpdateDelivery.record_result("gift_idea_added", item.id)
            show_added_item(item.id, already: status == :already, suggestion_id: suggestion.id)
          else
            context.notice = I18n.t("bot.gift_ideas.add_results.#{status}")
            show_ideas(suggestion.id)
          end
        end
      end

      # Read-only, also used to recover a committed add after a delivery failure.
      def show_added_item(item_id, already: false, suggestion_id: nil)
        item = user.items.includes(:wishlist).find(item_id)
        rows = [
          Presenters::GiftIdeasPresenter::SEARCH_URLS.keys.map do |store|
            inline_btn(I18n.t("bot.gift_ideas.search.#{store}"), nil,
                       url: Presenters::GiftIdeasPresenter.search_url(store, item.title))
          end,
          [ inline_btn(I18n.t("bot.gift_ideas.add_link"), "edit_item_field:url:#{item.id}") ]
        ]
        rows << [ inline_btn(I18n.t("bot.buttons.open_item"), "open_item:#{item.id}") ]
        if suggestion_id
          rows << [ inline_btn(I18n.t("bot.gift_ideas.back_to_ideas"), "show_gift_ideas:#{suggestion_id}") ]
        end
        rows << [ inline_btn(I18n.t("bot.buttons.back_to_list"), "open_list:#{item.wishlist_id}") ]
        message = I18n.t(already ? "bot.gift_ideas.already_added" : "bot.messages.item_added",
                         title: escape_html(item.title), list: escape_html(item.wishlist.title))
        context.render(message, build_keyboard(rows))
      end

      private

      def request_notice(status, wishlist)
        text = I18n.t("bot.gift_ideas.requests.#{status}",
                      date: Time.current.in_time_zone(GiftSuggestion::TIME_ZONE).tomorrow.strftime("%d.%m"))
        if %i[user_limit global_limit].include?(status) && GiftSuggestion.latest_ready_for(user, wishlist)
          text += " #{I18n.t('bot.gift_ideas.saved_hint', button: I18n.t('bot.gift_ideas.recent'))}"
        end
        text
      end

      def owned_suggestion(suggestion_id)
        suggestion = GiftSuggestion.where(user_id: user.id).find(suggestion_id)
        user.wishlists.find(suggestion.wishlist_id)
        suggestion
      end

      def disabled
        context.notice = I18n.t("bot.gift_ideas.requests.disabled")
      end
    end
  end
end
