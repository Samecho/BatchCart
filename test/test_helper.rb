ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module BatchTestData
  def shop(domain = Shop::DEMO_DOMAIN)
    Shop.find_or_create_by!(domain: domain)
  end

  def sample_rows(file = "order-template.csv")
    path = file == "order-template.csv" ? Rails.root.join("public", file) : Rails.root.join("test/fixtures/files", file)
    File.open(path, "rb") { |csv| BatchImport.read(csv) }
  end

  def import(shop, limit: 1)
    BatchImport.new(shop, sample_rows.first(limit)).save!(filename: "orders.csv", actor: "test")
  end

  def confirmed(shop, limit: 1)
    import(shop, limit: limit).tap { |batch| batch.update!(confirmed_at: Time.current) }
  end

  def shopify_reply(code, payload, headers = {})
    Struct.new(:code, :body, :headers) do
      def [](key) = headers[key]
    end.new(code.to_s, JSON.generate(payload), headers)
  end

  def with_config(**values)
    values = values.transform_keys(&:to_s)
    previous = ENV.to_h.slice(*values.keys)
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    values.each_key { |key| ENV[key] = previous[key] }
  end
end

class ActiveSupport::TestCase
  include BatchTestData
  setup { ENV["BATCHCART_DEMO"] = "1" }
end
