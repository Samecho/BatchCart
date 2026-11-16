class Shop < ApplicationRecord
  DOMAIN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.myshopify\.com\z/
  DEMO_DOMAIN = "demo.batchcart.test"

  has_many :batches
  has_many :batch_orders, through: :batches, source: :orders
  has_many :webhook_deliveries
  encrypts :access_token, :refresh_token

  def demo?
    domain == DEMO_DOMAIN && ENV["BATCHCART_DEMO"] == "1"
  end

  def api
    demo? ? Shopify::Demo.new(self) : Shopify::Admin.new(self)
  end

  # The lock is held on the same PostgreSQL connection across the HTTP request.
  # PostgreSQL releases it if a worker exits before it can record its result.
  def with_api_lock
    self.class.connection_pool.with_connection do |connection|
      key = 7_124_306_000_000_000 + id
      next false unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")

      begin
        reload
        yield
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{key})")
      end
    end
  end
end
