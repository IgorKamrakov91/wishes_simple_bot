# frozen_string_literal: true

module Bot
  module Presenters
    class ItemPresenter < BasePresenter
      object_name :item

      def initialize(item, user, context, reservations_page: nil, budget: nil)
        super(item, user, context)
        @reservations_page = reservations_page
        @guest_selection = GuestList.new(item.wishlist, budget: budget) unless owner? || reservations_page
        @budget = @guest_selection.budget if @guest_selection && budget
      end

      def text
        blocks = [ heading ]
        blocks << details if details.present?
        blocks << (owner? ? owner_status : guest_status)
        blocks.join("\n\n")
      end

      def keyboard
        context.build_keyboard(buttons)
      end

      # The shop's preview (title and a large photo) tops the card
      def link_preview_options
        return no_link_preview unless web_url

        Telegram::Bot::Types::LinkPreviewOptions.new(url: web_url.to_s, prefer_large_media: true, show_above_text: true)
      end

      private

      def heading
        lines = []
        # Old records can exceed today's validation limits. Bound the display
        # before escaping HTML, leaving stored values available for editing.
        lines << "<i>🎁 #{escape_html(wishlist.title.to_s.truncate(Wishlist::TITLE_LIMIT))} · #{t('bot.screens.item.position', index: position + 1, total: item_ids.size)}</i>"
        lines << "<b>#{escape_html(item.title.to_s.truncate(Item::TITLE_LIMIT))}</b>"
        lines << "<blockquote>#{escape_html(item.description.to_s.truncate(Item::DESCRIPTION_LIMIT))}</blockquote>" if item.description.present?
        lines.join("\n")
      end

      # Price and shop on one line: "6 000 ₽ · ozon.ru"
      def details
        @details ||= [
          ("<b>#{format_price(item.price)}</b>" if item.price.present?),
          (store_link if item.url.present?)
        ].compact.join(" · ")
      end

      def store_link
        return escape_html(item.url.to_s.truncate(100)) unless web_url

        "<a href=\"#{escape_html(web_url.to_s)}\">#{escape_html(web_url.host.delete_prefix('www.').truncate(100))}</a>"
      end

      # The owner never learns who reserved the gift
      def owner_status
        return t("bot.screens.item.owner_free") unless item.reserved?

        [ t("bot.screens.item.owner_reserved"), (t("bot.screens.item.owner_thanked") if item.thanked?) ].compact.join("\n")
      end

      # Who sees what stays one tap away in a collapsed quote
      def guest_status
        if !item.reserved?
          owner = escape_html((wishlist.owner.first_name.presence || wishlist.owner.full_name).to_s.truncate(60))
          [ t("bot.screens.item.guest_free"), collapsed(t("bot.screens.item.guest_free_privacy", owner: owner)) ].join("\n")
        elsif reserved_by_me?
          [ t("bot.screens.item.guest_mine"),
            (t("bot.screens.item.guest_purchased") if item.purchased?),
            collapsed(t("bot.screens.item.guest_mine_privacy")) ].compact.join("\n")
        else
          t("bot.screens.item.guest_taken", user: "<tg-spoiler>#{escape_html(reserver_label.to_s.truncate(60))}</tg-spoiler>")
        end
      end

      def collapsed(text)
        "<blockquote expandable>#{text}</blockquote>"
      end

      # A gift marked as bought asks first: releasing it also clears the mark
      # and opens it to other guests
      def release_data
        return "#{item.purchased? ? 'gc' : 'gu'}:#{item.id}:#{item.reservation_version}:#{@budget}" if @budget

        prefix = item.purchased? ? "confirm_release" : (@reservations_page ? "release_book" : "unreserve_item")
        [ prefix, item.id, item.reservation_version, @reservations_page ].compact.join(":")
      end

      def purchased_button
        value = item.purchased? ? 0 : 1
        data = [ "mark_purchased", item.id, item.reservation_version, value, @reservations_page ].compact.join(":")
        data = "gp:#{item.id}:#{item.reservation_version}:#{value}:#{@budget}" if @budget
        label = item.purchased? ? t("bot.buttons.not_purchased") : t("bot.buttons.purchased")
        context.inline_btn(label, data, **(item.purchased? ? {} : { style: "primary" }))
      end

      def reserver_label
        reserver = item.reserver
        return t("bot.presenters.item.unknown_reserver") unless reserver

        reserver.username.present? ? "@#{reserver.username}" : reserver.full_name
      end

      def buttons
        buttons = []

        unless owner?
          if !item.reserved?
            data = @budget ? "gr:#{item.id}:#{item.reservation_version}:#{@budget}" : "reserve_item:#{item.id}:#{item.reservation_version}"
            buttons << [ context.inline_btn(t("bot.buttons.reserve"), data, style: "success") ]
          elsif reserved_by_me?
            buttons << [ purchased_button, context.inline_btn(t("bot.buttons.unreserve"), release_data) ]
          end
        end

        buttons << [ context.inline_btn(t("bot.buttons.open_in_store"), url: web_url.to_s) ] if web_url

        # Thanks, returning and deleting wait behind "Gift received", so the
        # thanks read as being for the gift, not for the reservation
        if owner? && item.reserved?
          buttons << [ context.inline_btn(t("bot.buttons.gift_received"), "gift_received:#{item.id}:#{item.reservation_version}", style: "primary") ]
        end

        if owner?
          buttons << [
            context.inline_btn(t("bot.buttons.edit"), "edit_item:#{item.id}"),
            context.inline_btn(t("bot.buttons.delete"), "confirm_delete_item:#{item.id}", style: "danger")
          ]
        end

        back_page = owner? ? WishlistPresenter.page_of(position) : (@guest_selection || GuestList.new(wishlist)).page_for(item.id)
        back_data = @budget ? @guest_selection.page_callback(back_page) : "list_page:#{wishlist.id}:#{back_page}"
        back_to_list = context.inline_btn(t("bot.buttons.back_to_list"), back_data)
        if @reservations_page
          # Opened from My reservations: back to either, no neighbours
          buttons << [ back_to_list, context.inline_btn(t("bot.screens.reservations.back"), "show_reservations:#{@reservations_page}") ]
        else
          buttons << navigation_row(back_to_list)
          if !owner? && (reserved_by_me? || ReservationsPresenter.scope_for(user).exists?)
            page = reserved_by_me? ? ReservationsPresenter.page_for(item, user) : 0
            buttons << [ context.inline_btn(t("bot.screens.reservations.back"), "show_reservations:#{page}") ]
          end
        end
        buttons
      end

      # One row: ‹ previous, back to the list, next ›; only the steps that exist
      def navigation_row(back_to_list)
        previous_id = item_ids[position - 1] if position.positive?
        next_id = item_ids[position + 1]
        [
          (context.inline_btn(t("bot.buttons.prev_item"), item_callback(previous_id)) if previous_id),
          back_to_list,
          (context.inline_btn(t("bot.buttons.next_item"), item_callback(next_id)) if next_id)
        ].compact
      end

      # Only http(s) links can go into a URL button, anything else is shown as text
      def web_url
        return @web_url if defined?(@web_url)

        @web_url = item.web_uri
      end

      def wishlist
        item.wishlist
      end

      def item_ids
        @item_ids ||= begin
          ids = @guest_selection ? @guest_selection.items.map(&:id) : wishlist.items.pluck(:id)
          # An old button may open a gift whose price has since changed.
          # Keep its card usable even when it no longer matches the budget.
          ids.unshift(item.id) unless ids.include?(item.id)
          ids
        end
      end

      def item_callback(id)
        @budget ? @guest_selection.item_callback(id) : "open_item:#{id}"
      end

      def position
        item_ids.index(item.id) || 0
      end

      def reserved_by_me?
        item.reserved_by?(user)
      end

      def owner?
        wishlist.user_id == user.id
      end

      def reserver_label
        reserver = item.reserver
        return I18n.t("bot.presenters.item.unknown_reserver") unless reserver

        reserver.username.present? ? "@#{reserver.username}" : reserver.full_name
      end
    end
  end
end
