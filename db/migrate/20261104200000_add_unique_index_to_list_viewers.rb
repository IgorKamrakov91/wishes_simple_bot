class AddUniqueIndexToListViewers < ActiveRecord::Migration[8.1]
  def up
    # Keep the earliest row of each (wishlist, user) pair
    execute <<~SQL
      DELETE FROM list_viewers a
      USING list_viewers b
      WHERE a.wishlist_id = b.wishlist_id AND a.user_id = b.user_id AND a.id > b.id
    SQL

    add_index :list_viewers, [ :wishlist_id, :user_id ], unique: true
  end

  def down
    remove_index :list_viewers, [ :wishlist_id, :user_id ]
  end
end
