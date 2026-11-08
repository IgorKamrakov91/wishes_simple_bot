# frozen_string_literal: true

module Bot
  # Rebuilds a reply from current authorized data, never by replaying a write.
  class UpdateResultReply
    include Helpers

    class ResultContext < Context
      attr_accessor :result_note

      def render(text, keyboard = nil, **options)
        super("#{result_note}\n\n#{text}", keyboard, **options)
      end
    end

    def initialize(bot, source, receipt)
      @receipt = receipt
      @user = User.find_by(telegram_id: receipt.telegram_user_id)
      @context = ResultContext.new(bot: bot, user: @user, source: source)
      @context.result_note = I18n.t("bot.messages.update_results.#{receipt.result_kind}")
    end

    def render
      return unavailable unless @user

      check_access!
      if @user.bot_state.present?
        InputPrompt.new(@context).render
      else
        render_result
      end
    rescue ActiveRecord::RecordNotFound
      unavailable
    end

    private

    def check_access!
      case @receipt.result_kind
      when "list_view"
        Wishlist.accessible_to(@user).find(@receipt.result_id)
      when "list_created", "list_renamed", "gift_deleted"
        @user.wishlists.find(@receipt.result_id)
      when "gift_added", "gift_updated", "thanked", "gift_idea_added"
        @user.items.find(@receipt.result_id)
      when "gift_ideas"
        suggestion = GiftSuggestion.where(user_id: @user.id).find(@receipt.result_id)
        @user.wishlists.find(suggestion.wishlist_id)
      when "item_view", "reserved", "released", "purchased", "unpurchased"
        Item.accessible_to(@user).find(@receipt.result_id)
      end
    end

    def render_result
      case @receipt.result_kind
      when "list_view", "list_created", "list_renamed", "gift_deleted"
        Callbacks::WishlistHandler.new(@context).open_list(@receipt.result_id)
      when "item_view", "gift_added", "gift_updated", "reserved", "released", "purchased", "unpurchased", "thanked"
        Callbacks::ItemHandler.new(@context).show_item(@receipt.result_id)
      when "list_deleted"
        Callbacks::WishlistHandler.new(@context).show_lists
      when "settings_updated"
        Callbacks::SettingsHandler.new(@context).show_settings
      when "gift_ideas"
        Callbacks::GiftIdeasHandler.new(@context).show_ideas(@receipt.result_id)
      when "gift_idea_added"
        Callbacks::GiftIdeasHandler.new(@context).show_added_item(@receipt.result_id)
      when "reminder_updated"
        Callbacks::SettingsHandler.new(@context).show_reservation_reminders
      else
        Callbacks::WishlistHandler.new(@context).main_menu
      end
    end

    def unavailable
      keyboard = build_keyboard([
        [ inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu"), inline_btn(I18n.t("bot.buttons.help"), "help") ]
      ])
      @context.send_text(I18n.t("bot.messages.result_unavailable"), keyboard)
    end
  end
end
