class AddPurchasedAtToItems < ActiveRecord::Migration[8.1]
  def change
    # Set by the guest who reserved the gift once it is bought, so reminders
    # skip it. It belongs to the reservation and is cleared when that ends;
    # the owner never sees it.
    add_column :items, :purchased_at, :datetime
  end
end
