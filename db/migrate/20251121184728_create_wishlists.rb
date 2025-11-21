class CreateWishlists < ActiveRecord::Migration[8.1]
  def change
    create_table :wishlists do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title, null: false

      t.timestamps
    end
  end
end
