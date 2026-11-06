# frozen_string_literal: true

module Bot
  module Callbacks
    class ItemHandler < BaseHandler
      def show_item(item_id, reservations_page: nil)
        scope = reservations_page.nil? ? Item.accessible_to(user) : Presenters::ReservationsPresenter.scope_for(user)
        item = scope.includes(wishlist: :user).find(item_id)
        presenter = Presenters::ItemPresenter.new(item, user, context, reservations_page: reservations_page)
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

        current = item.public_send(field)
        rows = []
        if current.present? && Item::OPTIONAL_FIELDS.include?(field)
          rows << [ context.inline_btn(I18n.t("bot.buttons.clear_field"), "clear_item_field:#{field}:#{item.id}") ]
        end
        rows << [ context.inline_btn(I18n.t("bot.buttons.cancel"), "open_item:#{item.id}") ]

        context.render(edit_prompt_text(field, current), context.build_keyboard(rows))
      end

      # Removes an optional value, in place of typing "-"
      def clear_item_field(field, item_id)
        item = user.items.find(item_id)
        return unless Item::OPTIONAL_FIELDS.include?(field)

        item.update!(field => nil)
        context.notice = I18n.t("bot.messages.field_cleared")
        show_item(item.id)
      end

      # Saves the gift being added without a link. The button carries the
      # draft id, so a button left from an earlier gift can't save this one.
      def skip_item_url(draft_id = nil)
        user.with_lock do
          if current_draft?(draft_id.to_s.presence)
            StateHandler.new(context).save_item_without_link
          else
            context.notice = I18n.t("bot.messages.button_outdated")
          end
        end
      end

      def reserve_item(item_id, reservation_version)
        item = Item.accessible_to(user).find(item_id)
        wishlist = item.wishlist

        if wishlist.user_id == user.id
          context.notice = I18n.t("bot.messages.cannot_reserve_own")
        elsif item.reserve_for!(user, expected_version: reservation_version)
          context.notice = I18n.t("bot.messages.reserved_notice")
          ReservationNotifier.reserved(item, by: user)
        elsif item.reserved_by?(user)
          context.notice = I18n.t("bot.messages.reserved_notice")
        elsif item.reserved_by_other?(user)
          context.notice = I18n.t("bot.messages.already_reserved")
        else
          context.notice = I18n.t("bot.messages.reservation_changed")
        end

        show_item(item.id)
      end

      def unreserve_item(item_id, reservation_version, reservations_page = nil)
        item = Item.accessible_to(user).find(item_id)
        wishlist = item.wishlist

        if wishlist.user_id == user.id
          context.notice = I18n.t("bot.messages.cannot_reserve_own")
        elsif item.release_for!(user, expected_version: reservation_version)
          context.notice = I18n.t("bot.messages.unreserved_notice")
          ReservationNotifier.released(item, by: user)
        elsif !item.reserved?
          context.notice = I18n.t("bot.messages.unreserved_notice")
        elsif item.reserved_by_other?(user)
          context.notice = I18n.t("bot.messages.already_reserved")
        else
          context.notice = I18n.t("bot.messages.reservation_changed")
        end

        if reservations_page
          ReservationsHandler.new(context).show_reservations(reservations_page)
        else
          show_item(item.id)
        end
      end

      # Old toggle buttons do not encode whether the user intended to reserve
      # or release. Refresh them into explicit actions without changing data.
      def toggle_reserve(item_id)
        item = Item.accessible_to(user).find(item_id)
        context.notice = I18n.t("bot.messages.reservation_changed")
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
        page = Presenters::WishlistPresenter.page_of(wishlist.items.pluck(:id).index(item.id).to_i)

        item.destroy!

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

      def edit_prompt_text(field, current)
        lines = [ I18n.t("bot.messages.enter_new_value", field: I18n.t("bot.fields.#{field}")) ]
        hint = I18n.t("bot.input_hints.#{field}", default: nil)
        lines << "<i>#{hint}</i>" if hint
        if current.present?
          shown = field == "price" ? format_price(current) : current.to_s.truncate(200)
          lines << "\n#{I18n.t('bot.messages.current_value')}: #{escape_html(shown)}"
        end
        lines.join("\n")
      end
    end
  end
end
