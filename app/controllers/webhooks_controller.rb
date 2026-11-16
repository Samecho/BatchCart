class WebhooksController < ActionController::Base
  DRAFT_TOPICS = %w[draft_orders/create draft_orders/update draft_orders/delete].freeze

  def create
    body = request.raw_post
    secret = ENV["SHOPIFY_CLIENT_SECRET"]
    return head :unauthorized if secret.blank?

    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, body))
    return head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(signature, request.headers["X-Shopify-Hmac-Sha256"].to_s)

    topic = request.headers["X-Shopify-Topic"].to_s
    return head :ok unless topic.in?(DRAFT_TOPICS + ["app/uninstalled"])

    delivery_id = request.headers["X-Shopify-Webhook-Id"].to_s
    return head :bad_request unless /\A[\w-]{1,120}\z/.match?(delivery_id)

    domain = request.headers["X-Shopify-Shop-Domain"].to_s
    shop = Shop.find_by(domain: domain) if Shopify::OAuth.allowed?(domain)
    return head :ok unless shop

    payload = JSON.parse(body)
    return head :bad_request unless payload.is_a?(Hash)

    WebhookDelivery.transaction do
      created = shop.webhook_deliveries.insert_all(
        [{ delivery_id: delivery_id, topic: topic, created_at: Time.current }],
        unique_by: [:shop_id, :delivery_id]
      )
      next if created.rows.empty?

      if topic == "app/uninstalled"
        uninstall(shop, payload)
      else
        expedite_read(shop, payload)
      end
    end
    head :ok
  rescue JSON::ParserError, ArgumentError
    head :bad_request
  end

  private

  def expedite_read(shop, payload)
    gid = payload["admin_graphql_api_id"].to_s
    if gid.empty? && /\A[1-9]\d{0,19}\z/.match?(payload["id"].to_s)
      gid = "gid://shopify/DraftOrder/#{payload['id']}"
    end
    return unless /\Agid:\/\/shopify\/DraftOrder\/[1-9]\d{0,19}\z/.match?(gid)

    # Delivery order is irrelevant. The next sync reads the current state from Shopify.
    shop.batch_orders.where(remote_id: gid, status: "succeeded").where.not(remote_status: "DELETED")
      .update_all(sync_at: Time.current)
  end

  def uninstall(shop, payload)
    return unless payload["myshopify_domain"] == shop.domain

    timestamp = Time.iso8601(request.headers["X-Shopify-Triggered-At"].to_s)
    shop.with_lock do
      next unless shop.connected_at && timestamp >= shop.connected_at

      shop.update!(access_token: nil, refresh_token: nil, token_expires_at: nil,
                   connected_at: nil, session_version: shop.session_version + 1)
    end
  end
end
