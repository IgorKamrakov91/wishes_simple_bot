# A guest's list selection, carried in buttons rather than the user's input
# state. Unpriced gifts remain visible for every numeric budget.
module Bot
  class GuestList
    BUDGETS = %w[a s m l h n].freeze
    CALLBACK_PATTERN = /\Ag[lfirupc]:\d+(?::\d+)*:([asmlhn])\z/

    attr_reader :budget

    def self.normalize(budget)
      BUDGETS.include?(budget) ? budget : "a"
    end

    def self.budget_from_callback(data)
      CALLBACK_PATTERN.match(data.to_s)&.captures&.first
    end

    def self.page_from_callback(data)
      /\Ag[lf]:\d+:(\d+):[asmlhn]\z/.match(data.to_s)&.captures&.first&.to_i
    end

    def initialize(wishlist, budget: nil)
      @wishlist = wishlist
      @budget = self.class.normalize(budget)
    end

    def items
      @items ||= @wishlist.items.to_a.select { |item| within_budget?(item.price) }
        .sort_by { |item| [ item.reserved? ? 1 : 0, item.id ] }
    end

    def page_for(item_id)
      Presenters::WishlistPresenter.page_of(items.index { |item| item.id == item_id } || 0)
    end

    def page_callback(page)
      "gl:#{@wishlist.id}:#{page}:#{budget}"
    end

    def menu_callback(page)
      "gf:#{@wishlist.id}:#{page}:#{budget}"
    end

    def item_callback(item_id)
      "gi:#{item_id}:#{budget}"
    end

    def label
      I18n.t("bot.guest_budget.options.#{budget}")
    end

    private

    def within_budget?(price)
      return true if budget == "a" || price.nil?

      case budget
      when "s" then price <= 1000
      when "m" then price <= 3000
      when "l" then price <= 10_000
      when "h" then price > 10_000
      when "n" then false
      end
    end
  end
end
