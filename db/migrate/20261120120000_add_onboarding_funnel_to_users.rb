class AddOnboardingFunnelToUsers < ActiveRecord::Migration[8.1]
  def up
    # Existing accounts must not become newcomers merely because they never
    # saved a gift. New accounts opt in after this migration commits.
    add_column :users, :onboarding_eligible, :boolean, default: false, null: false
    add_column :users, :first_contact_at, :datetime
    add_column :users, :first_contact_kind, :string
    add_column :users, :acquisition_source, :string
    add_column :users, :first_private_start_at, :datetime
    add_column :users, :first_list_at, :datetime
    add_column :users, :first_item_at, :datetime
    add_column :users, :first_share_query_at, :datetime
    add_column :users, :first_shared_list_open_at, :datetime

    # Recover only facts supported by surviving records; no invented source,
    # contact time or gift timestamp for an empty legacy account.
    execute <<~SQL
      UPDATE users SET first_list_at = first_lists.created_at
      FROM (SELECT user_id, MIN(created_at) AS created_at FROM wishlists GROUP BY user_id) first_lists
      WHERE users.id = first_lists.user_id
    SQL
    execute <<~SQL
      UPDATE users SET first_item_at = first_items.created_at
      FROM (
        SELECT wishlists.user_id, MIN(items.created_at) AS created_at
        FROM items JOIN wishlists ON wishlists.id = items.wishlist_id
        GROUP BY wishlists.user_id
      ) first_items
      WHERE users.id = first_items.user_id
    SQL
    change_column_default :users, :onboarding_eligible, from: false, to: true
  end

  def down
    remove_columns :users, :onboarding_eligible, :first_contact_at, :first_contact_kind,
                   :acquisition_source, :first_private_start_at, :first_list_at, :first_item_at,
                   :first_share_query_at, :first_shared_list_open_at
  end
end
