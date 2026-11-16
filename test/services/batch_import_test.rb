require "test_helper"

class BatchImportTest < ActiveSupport::TestCase
  test "unknown and ambiguous SKUs, duplicate lines and inconsistent recipients are tied to each record" do
    rows = sample_rows
    rows[1]["sku"] = rows[0]["sku"]
    rows[1]["city"] = "Different city"
    rows[2]["sku"] = "MISSING"
    rows[2]["first_name"] = ""
    variants = Shopify::Demo::CATALOG.fetch("GIFT-MUG")
    client = Object.new
    client.define_singleton_method(:variants) { |_| { "GIFT-MUG" => [variants, variants.merge("id" => "another-mug")] } }
    Shopify::Demo.stub(:new, client) do
      batch = BatchImport.new(shop, rows).save!(filename: "orders.csv", actor: "test")
      assert_empty batch.orders
      issues = batch.issues.group_by { |error| error["row"] }
      assert_match(/More than one/, issues[2].sole["message"])
      assert_equal %w[city sku sku], issues[3].pluck("field").sort
      assert_equal %w[first_name sku], issues[4].pluck("field").sort
    end
  end

  test "the database rejects changes to a saved payload and new orders on a confirmed batch" do
    batch = confirmed(shop)
    order = batch.orders.sole
    assert_raises(ActiveRecord::StatementInvalid) do
      Batch.transaction(requires_new: true) { batch.update!(rows: []) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      BatchOrder.transaction(requires_new: true) { order.update!(request_data: {}) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      BatchOrder.transaction(requires_new: true) do
        batch.orders.create!(reference: "new", marker: "new", fingerprint: "new", request_data: { "items" => [] })
      end
    end
  end
end
