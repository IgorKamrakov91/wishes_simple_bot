# frozen_string_literal: true

module Bot
  module Presenters
    class ItemPresenter < BasePresenter
      object_name :item

      def initialize(item, user, context, reservations_page: nil)
        super(item, user, context)
        @reservations_page = reservations_page
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
        lines << "<i>🎁 #{escape_html(wishlist.title)} · #{t('bot.screens.item.position', index: position + 1, total: item_ids.size)}</i>"
        lines << "<b>#{escape_html(item.title)}</b>"
        lines << "<blockquote>#{escape_html(item.description)}</blockquote>" if item.description.present?
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
        return escape_html(item.url) unless web_url

        "<a href=\"#{escape_html(web_url.to_s)}\">#{escape_html(web_url.host.delete_prefix('www.'))}</a>"
      end

      # The owner never learns who reserved the gift
      def owner_status
        item.reserved? ? t("bot.screens.item.owner_reserved") : t("bot.screens.item.owner_free")
      end

      # Who sees what stays one tap away in a collapsed quote
      def guest_status
        if !item.reserved?
          owner = escape_html(wishlist.owner.first_name.presence || wishlist.owner.full_name)
          [ t("bot.screens.item.guest_free"), collapsed(t("bot.screens.item.guest_free_privacy", owner: owner)) ].join("\n")
        elsif reserved_by_me?
          [ t("bot.screens.item.guest_mine"),
            (t("bot.screens.item.guest_purchased") if item.purchased?),
            collapsed(t("bot.screens.item.guest_mine_privacy")) ].compact.join("\n")
        else
          t("bot.screens.item.guest_taken", user: "<tg-spoiler>#{escape_html(reserver_label)}</tg-spoiler>")
        end
      end

      def collapsed(text)
        "<blockquote expandable>#{text}</blockquote>"
      end

      def purchased_button
        value = item.purchased? ? 0 : 1
        data = [ "mark_purchased", item.id, item.reservation_version, value, @reservations_page ].compact.join(":")
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
            buttons << [ context.inline_btn(t("bot.buttons.reserve"), "reserve_item:#{item.id}:#{item.reservation_version}", style: "success") ]
          elsif reserved_by_me?
            release = if @reservations_page
              "release_book:#{item.id}:#{item.reservation_version}:#{@reservations_page}"
            else
              "unreserve_item:#{item.id}:#{item.reservation_version}"
            end
            buttons << [ purchased_button, context.inline_btn(t("bot.buttons.unreserve"), release) ]
          end
        end

        buttons << [ context.inline_btn(t("bot.buttons.open_in_store"), url: web_url.to_s) ] if web_url

        if owner?
          buttons << [
            context.inline_btn(t("bot.buttons.edit"), "edit_item:#{item.id}"),
            context.inline_btn(t("bot.buttons.delete"), "confirm_delete_item:#{item.id}", style: "danger")
          ]
        end

        back_to_list = context.inline_btn(t("bot.buttons.back_to_list"), "list_page:#{wishlist.id}:#{WishlistPresenter.page_of(position)}")
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
          (context.inline_btn(t("bot.buttons.prev_item"), "open_item:#{previous_id}") if previous_id),
          back_to_list,
          (context.inline_btn(t("bot.buttons.next_item"), "open_item:#{next_id}") if next_id)
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
        @item_ids ||= wishlist.items.pluck(:id)
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
