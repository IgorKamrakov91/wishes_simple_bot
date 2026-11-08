class AddThankedAtToItems < ActiveRecord::Migration[8.1]
  def change
    add_column :items, :thanked_at, :datetime
  end
end
