class CreateDemoDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_drafts do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :marker, null: false
      t.timestamps
    end
    add_index :demo_drafts, [:shop_id, :marker]
  end
end
