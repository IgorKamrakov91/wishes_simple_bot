# frozen_string_literal: true

module Bot
  module Callbacks
    class ItemHandler < BaseHandler
      def show_item(item_id)
        item = Item.accessible_to(user).includes(wishlist: :user).find(item_id)
        presenter = Presenters::ItemPresenter.new(item, user, context)
        context.render(presenter.text, presenter.keyboard, link_preview_options: presenter.link_preview_options)
      end

      def add_item_prompt(wishlist_id)
        user.wishlists.find(wishlist_id)
        user.start_adding_item!(wishlist_id: wishlist_id)
        context.render(I18n.t("bot.messages.enter_item_name"), cancel_keyboard("open_list:#{wishlist_id}"))
      end

      def edit_item_menu(item_id)
        item = user.items.find(item_id)

        buttons = Item::EDITABLE_FIELDS.map do |field|
          context.inline_btn(I18n.t("bot.fields.#{field}"), "edit_item_field:#{field}:#{item.id}")
        end
        keyboard = context.build_keyboard([
          *buttons.each_slice(2).to_a,
          [ context.inline_btn(I18n.t("bot.buttons.back"), "open_item:#{item.id}") ]
        ])

        context.render(I18n.t("bot.messages.what_to_edit", title: escape_html(item.title)), keyboard)
      end

      def edit_item_field_prompt(field, item_id)
        item = user.items.find(item_id)
        return context.send_text(I18n.t("bot.messages.error")) unless Item::EDITABLE_FIELDS.include?(field)

        user.update!(
          bot_state: "editing_item",
          bot_payload: { item_id: item.id, field: field }
        )

        context.render(
          I18n.t("bot.messages.enter_new_value", field: I18n.t("bot.fields.#{field}")),
          cancel_keyboard("open_item:#{item.id}")
        )
      end

      # Saves the gift being added without a link. The button carries the
      # draft id, so a button left from an earlier gift can't save this one.
      def skip_item_url(draft_id = nil)
        user.with_lock do
          if current_draft?(draft_id.to_s.presence)
            StateHandler.new(context).handle
          else
            context.notice = I18n.t("bot.messages.button_outdated")
          end
        end
      end

      def toggle_reserve(item_id)
        item = Item.accessible_to(user).find(item_id)
        wishlist = item.wishlist

        if wishlist.user_id == user.id
          context.notice = I18n.t("bot.messages.cannot_reserve_own")
        elsif item.reserved_by_other?(user)
          context.notice = I18n.t("bot.messages.already_reserved")
        elsif item.reserved_by?(user)
          item.release_reservation!
          context.notice = I18n.t("bot.messages.unreserved_notice")
          notify_viewers(wishlist, I18n.t("bot.messages.reserve_lifted", title: item.title, list_title: wishlist.title, list_owner: wishlist.owner.full_name))
        else
          item.reserve_for!(user)
          context.notice = I18n.t("bot.messages.reserved_notice")
          notify_viewers(wishlist, I18n.t("bot.messages.reserved_by", title: item.title, list_title: wishlist.title, user: "@#{user.full_name}"))
        end

        show_item(item.id)
      end

      def confirm_delete_item(item_id)
        item = user.items.find(item_id)

        keyboard = context.build_keyboard([
          [
            context.inline_btn(I18n.t("bot.buttons.confirm_delete"), "delete_item:#{item.id}", style: "danger"),
            context.inline_btn(I18n.t("bot.buttons.cancel"), "open_item:#{item.id}")
          ]
        ])

        context.render(I18n.t("bot.messages.confirm_delete_item", title: escape_html(item.title)), keyboard)
      end

      def delete_item(item_id)
        item = user.items.find(item_id)
        wishlist = item.wishlist
        item_title = item.title
        page = Presenters::WishlistPresenter.page_of(wishlist.items.pluck(:id).index(item.id).to_i)

        item.destroy!

        # Disable notification about item deletion
        # notify_viewers(wishlist, I18n.t("bot.messages.item_deleted", title: item_title))

        context.notice = I18n.t("bot.messages.item_deleted_success")
        WishlistHandler.new(context).open_list(wishlist.id, page)
      end

      private

      # Read under the lock taken in skip_item_url
      def current_draft?(draft_id)
        payload = user.bot_payload || {}
        return false unless user.bot_state == "adding_item_url"

        draft_id ? payload["draft_id"] == draft_id : payload.key?("item_id")
      end
    end
  end
end
