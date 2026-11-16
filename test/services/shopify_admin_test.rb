require "test_helper"

class ShopifyAdminTest < ActiveSupport::TestCase
  setup do
    @demo = shop
    @live = shop("graphql-example.myshopify.com")
    @live.update!(access_token: "fake", connected_at: Time.current)
    @old_dev_shops = ENV["SHOPIFY_DEV_SHOPS"]
    ENV["SHOPIFY_DEV_SHOPS"] = @live.domain
  end
  teardown { ENV["SHOPIFY_DEV_SHOPS"] = @old_dev_shops }

  test "catalog search keeps exact matches across cursor pages" do
    mug = { id: "variant-1", sku: "GIFT-MUG", title: "Cream", product: { title: "Camp mug" } }
    seen = []
    transport = lambda do |_, _, body, _|
      variables = body.fetch(:variables)
      assert_equal 'sku:"GIFT-MUG" OR sku:"GIFT-TEE"', variables[:search]
      cursor = variables[:cursor]
      seen << cursor
      nodes = cursor ? [mug.merge(id: "variant-2")] : [mug, mug.merge(sku: "GIFT-MUG-LARGE")]
      shopify_reply(200, { data: { productVariants: {
        nodes: nodes, pageInfo: { hasNextPage: cursor.nil?, endCursor: "next-page" }
      } } })
    end
    Shopify::Transport.stub(:post, transport) do
      variants = @live.api.variants(%w[GIFT-MUG GIFT-TEE])
      assert_equal [nil, "next-page"], seen
      assert_equal %w[variant-1 variant-2], variants.fetch("GIFT-MUG").pluck("id")
      refute variants.key?("GIFT-TEE")
    end
  end

  test "the draft mutation sends variant IDs and a reconciliation marker" do
    order = confirmed(@demo).orders.sole
    transport = lambda do |domain, path, body, headers|
      assert_equal @live.domain, domain
      assert_equal "/admin/api/2026-10/graphql.json", path
      assert_equal "fake", headers["X-Shopify-Access-Token"]
      input = body.dig(:variables, :input)
      assert_includes input[:tags], order.marker
      assert_equal [{ variantId: "demo-mug", quantity: 2 }], input[:lineItems]
      assert_equal false, input[:visibleToCustomer]
      shopify_reply(200, { data: { draftOrderCreate: { draftOrder: { id: "gid://shopify/DraftOrder/27" } } } })
    end
    Shopify::Transport.stub(:post, transport) do
      assert_equal "gid://shopify/DraftOrder/27", @live.api.create_draft(order)["id"]
    end
  end

  test "HTTP and GraphQL throttles delay the next worker attempt" do
    catalog = Shopify::Demo.new(@demo)
    Shopify::Admin.stub(:new, catalog) { @batch = confirmed(@live) }
    order = @batch.orders.sole
    throttled = shopify_reply(200, {
      errors: [{ extensions: { code: "THROTTLED" } }],
      extensions: { cost: { requestedQueryCost: 100, throttleStatus: { currentlyAvailable: 20, restoreRate: 10 } } }
    }, "x-request-id" => "rate-check")
    http_throttled = shopify_reply(429, {}, "retry-after" => "12")
    replies = [throttled, http_throttled]
    Shopify::Transport.stub(:post, ->(*) { replies.shift || flunk("Mutation sent before cooldown") }) do
      RunShopJob.perform_now(@live.id)
      assert_equal "pending", order.reload.status
      assert_in_delta Time.current + 8, order.next_attempt_at, 1
      RunShopJob.perform_now(@live.id)
      assert_equal 1, replies.size
      travel 9.seconds do
        RunShopJob.perform_now(@live.id)
        assert_in_delta Time.current + 12, order.reload.next_attempt_at, 1
        assert_in_delta Time.current + 12, @live.reload.api_available_at, 1
      end
    end
  end

  test "network and gateway failures during mutation have unknown outcomes" do
    order = confirmed(@demo).orders.sole
    [
      ->(*) { raise Net::ReadTimeout },
      ->(*) { shopify_reply(502, {}) },
      ->(*) { shopify_reply(200, { errors: [{ extensions: { code: "INTERNAL_SERVER_ERROR" } }] }) }
    ].each do |reply|
      Shopify::Transport.stub(:post, reply) do
        error = assert_raises(Shopify::Error) { @live.api.create_draft(order) }
        assert_equal :unknown, error.kind
      end
    end
  end

  test "Shopify user errors and permission failures are explicit rejections" do
    order = confirmed(@demo).orders.sole
    [
      [shopify_reply(200, { data: { draftOrderCreate: { draftOrder: nil, userErrors: [{ field: ["lineItems"] }] } } }), "shopify_rejected_draft"],
      [shopify_reply(403, {}), "shopify_permission"]
    ].each do |reply, code|
      Shopify::Transport.stub(:post, reply) do
        error = assert_raises(Shopify::Error) { @live.api.create_draft(order) }
        assert_equal :rejected, error.kind
        assert_equal code, error.code
      end
    end
  end
end
