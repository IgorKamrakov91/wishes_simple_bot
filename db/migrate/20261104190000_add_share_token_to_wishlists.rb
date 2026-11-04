class AddShareTokenToWishlists < ActiveRecord::Migration[8.1]
  class MigrationWishlist < ActiveRecord::Base
    self.table_name = "wishlists"
  end

  def up
    add_column :wishlists, :share_token, :string

    MigrationWishlist.reset_column_information
    MigrationWishlist.find_each do |wishlist|
      wishlist.update_columns(share_token: SecureRandom.base58(24))
    end

    change_column_null :wishlists, :share_token, false
    add_index :wishlists, :share_token, unique: true
  end

  def down
    remove_index :wishlists, :share_token
    remove_column :wishlists, :share_token
  end
end
