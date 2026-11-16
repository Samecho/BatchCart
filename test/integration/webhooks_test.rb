require "test_helper"

class WebhooksTest < ActionDispatch::IntegrationTest
  setup do
    @forgery_protection = WebhooksController.allow_forgery_protection
    WebhooksController.allow_forgery_protection = true
    @shop = shop("webhook-example.myshopify.com")
    Shopify::Admin.stub(:new, Shopify::Demo.new(@shop)) do
      @order = confirmed(@shop).orders.sole
    end
    @remote = {
      "id" => "gid://shopify/DraftOrder/31", "name" => "#D31", "status" => "COMPLETED",
      "updatedAt" => Time.current.iso8601(6)
    }
    @order.update_remote!(@remote)
  end

  teardown do
    WebhooksController.allow_forgery_protection = @forgery_protection
  end

  test "signature verification and delivery IDs are independent of draft state" do
    with_config(SHOPIFY_CLIENT_SECRET: "webhook-test-secret", SHOPIFY_DEV_SHOPS: @shop.domain) do
      deliver(headers: { "X-Shopify-Hmac-Sha256" => "bad" })
      assert_response :unauthorized
      assert_equal 0, @shop.webhook_deliveries.count
      assert_difference("WebhookDelivery.count", 1) do
        2.times do
          deliver
          assert_response :ok
        end
      end
      assert @order.reload.sync_at
      assert_equal "COMPLETED", @order.remote_status

      old_remote = @remote.merge("status" => "OPEN", "updatedAt" => 1.day.ago.iso8601(6))
      client = Object.new
      client.define_singleton_method(:draft) { |_| old_remote }
      Shopify::Admin.stub(:new, client) { SyncShopJob.perform_now(@shop.id) }
      assert_equal "COMPLETED", @order.reload.remote_status
    end
  end

  test "an old uninstall cannot disconnect a new installation" do
    @shop.update!(connected_at: Time.current, access_token: "new-token")
    with_config(SHOPIFY_CLIENT_SECRET: "webhook-test-secret", SHOPIFY_DEV_SHOPS: @shop.domain) do
      deliver(topic: "app/uninstalled", body: { myshopify_domain: @shop.domain }, headers: {
        "X-Shopify-Triggered-At" => 1.day.ago.iso8601
      })
      assert_response :ok
      assert_equal "new-token", @shop.reload.access_token

      deliver(topic: "app/uninstalled", body: { myshopify_domain: @shop.domain }, headers: {
        "X-Shopify-Triggered-At" => 1.second.from_now.iso8601, "X-Shopify-Webhook-Id" => "real-uninstall"
      })
      assert_response :ok
      assert_nil @shop.reload.access_token
      assert_nil @shop.connected_at
    end
  end

  private

  def deliver(topic: "draft_orders/update", body: { id: 31, status: "open" }, headers: {})
    raw = JSON.generate(body)
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", ENV.fetch("SHOPIFY_CLIENT_SECRET"), raw))
    post "/webhooks/shopify", params: raw, headers: {
      "CONTENT_TYPE" => "application/json", "X-Shopify-Hmac-Sha256" => signature,
      "X-Shopify-Topic" => topic, "X-Shopify-Webhook-Id" => "example-delivery", "X-Shopify-Shop-Domain" => @shop.domain
    }.merge(headers)
  end
end
