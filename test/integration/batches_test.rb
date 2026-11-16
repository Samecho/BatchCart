require "test_helper"

class BatchesTest < ActionDispatch::IntegrationTest
  setup do
    post "/auth/demo"
    assert_response :no_content
    @shop = shop
  end

  test "upload validates by record and confirmation is required after editing" do
    post "/api/batches", params: { file: fixture_file_upload("mixed.csv", "text/csv") }
    assert_response :created
    batch = response.parsed_body
    assert_equal "needs_changes", batch["state"]
    assert_equal [4, "quantity"], batch.fetch("issues").sole.values_at("row", "field")
    assert_equal [2, 3], batch.fetch("orders").sole.fetch("items").pluck("row")
    old_path = "/api/batches/#{batch['id']}"

    assert_no_difference("DemoDraft.count") do
      RunShopJob.perform_now(@shop.id)
      post "#{old_path}/confirm", as: :json
      assert_response :unprocessable_content
    end

    rows = batch["rows"]
    rows.last["quantity"] = "2"
    post "#{old_path}/revise", params: { rows: rows }, as: :json
    assert_response :created
    revision = response.parsed_body
    assert_equal 2, revision["version"]
    get old_path
    assert_equal "superseded", response.parsed_body["state"]
    assert_equal "0", response.parsed_body["rows"].last["quantity"]

    path = "/api/batches/#{revision['id']}"
    2.times do
      post "#{path}/confirm", as: :json
      assert_response :ok
    end
    assert_equal 1, Batch.find(revision["id"]).audit_events.where(action: "confirmed").count
    assert_difference("DemoDraft.count", 2) { 2.times { RunShopJob.perform_now(@shop.id) } }

    get "#{path}/export"
    assert_response :ok
    result = CSV.parse(response.body, headers: true)
    assert_equal %w[2 3 4], result["csv_row"]
    assert_equal result[0]["shopify_draft_id"], result[1]["shopify_draft_id"]
    assert result[2]["shopify_draft_id"].start_with?("gid://batchcart-demo/")
  end

  test "confirmation rechecks cross-batch duplicates against newly confirmed imports" do
    first = import(@shop)
    second = import(@shop)
    get "/api/batches/#{second.id}"
    assert_empty response.parsed_body["duplicate_references"]
    post "/api/batches/#{first.id}/confirm", as: :json
    assert_response :ok
    post "/api/batches/#{second.id}/confirm", as: :json
    assert_response :conflict
    assert_equal ["GIFT-101"], response.parsed_body["duplicate_references"]
    post "/api/batches/#{second.id}/confirm", params: { duplicate_references: ["GIFT-101"] }, as: :json
    assert_response :ok
  end

  test "only explicit rejections can return to the queue" do
    batch = confirmed(@shop, limit: 3)
    rejected, uncertain = batch.orders.order(:id)
    rejected.update!(status: "failed", error_code: "shopify_rejected_draft")
    uncertain.update!(status: "review", error_code: "shopify_transport")
    uncertain_path = "/api/batches/#{batch.id}/orders/#{uncertain.id}"
    post "#{uncertain_path}/retry", as: :json
    assert_response :unprocessable_content
    post "#{uncertain_path}/close", as: :json
    assert_response :unprocessable_content
    post "#{uncertain_path}/close", params: { acknowledged: true }, as: :json
    assert_response :no_content
    assert_equal "closed", uncertain.reload.status

    post "/api/batches/#{batch.id}/orders/#{rejected.id}/retry", as: :json
    assert_response :no_content
    assert_equal "pending", rejected.reload.status
  end

  test "two authenticated shops cannot read, export, revise, confirm or operate on each other's orders" do
    domains = %w[east-sample.myshopify.com west-sample.myshopify.com]
    with_config(APP_URL: "https://www.example.com", SHOPIFY_CLIENT_ID: "test-id",
                SHOPIFY_CLIENT_SECRET: "oauth-test-secret", SECRET_KEY_BASE: "s" * 80,
                DATA_ENCRYPTION_KEY: "test-key", SHOPIFY_DEV_SHOPS: domains.join(",")) do
      east = sign_in_to_shop(domains[0])
      west = sign_in_to_shop(domains[1])
      Shopify::Admin.stub(:new, Shopify::Demo.new(@shop)) do
        mine = import(Shop.find_by!(domain: domains[0]))
        theirs = import(Shop.find_by!(domain: domains[1]))
        west.get "/api/batches"
        assert_equal [theirs.id], west.response.parsed_body["batches"].pluck("id")
        assert_hidden_batch(west, mine)
        assert_hidden_batch(east, theirs)
        east.post "/api/batches/#{mine.id}/orders/#{theirs.orders.sole.id}/retry", as: :json
        assert_equal 404, east.response.status
      end
    end
  end

  private

  def sign_in_to_shop(domain)
    browser = open_session
    browser.https!
    browser.post "/auth/shopify", params: { shop: domain }, as: :json
    authorize_url = browser.response.parsed_body.fetch("url")
    scopes = Shopify::OAuth::SCOPES.join(",")
    replies = [
      { "associated_user" => { "id" => 42, "account_owner" => true }, "associated_user_scope" => scopes },
      { "scope" => scopes, "access_token" => "fake-access", "refresh_token" => "fake-refresh", "expires_in" => 3600 }
    ]
    Shopify::OAuth.stub(:exchange, ->(*, **) { replies.shift }) do
      2.times do
        state = URI.decode_www_form(URI.parse(authorize_url).query).to_h.fetch("state")
        query = { "code" => "authorized-code", "shop" => domain, "state" => state, "timestamp" => Time.current.to_i }
        message = query.sort.map { |key, value| "#{key}=#{value}" }.join("&")
        query["hmac"] = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("SHOPIFY_CLIENT_SECRET"), message)
        browser.get "/auth/shopify/callback", params: query
        assert_equal 302, browser.response.status
        authorize_url = browser.response.location
      end
    end
    assert_equal "/", URI.parse(authorize_url).path
    stored = Shop.connection.select_value("SELECT access_token FROM shops WHERE domain = #{Shop.connection.quote(domain)}")
    refute_includes stored, "fake-access"
    browser
  end

  def assert_hidden_batch(browser, batch)
    browser.get "/api/batches/#{batch.id}"
    assert_equal 404, browser.response.status
    browser.get "/api/batches/#{batch.id}/export"
    assert_equal 404, browser.response.status
    %w[revise confirm pause resume].each do |action|
      browser.post "/api/batches/#{batch.id}/#{action}", as: :json
      assert_equal 404, browser.response.status
    end
    %w[retry reconcile close].each do |action|
      browser.post "/api/batches/#{batch.id}/orders/#{batch.orders.sole.id}/#{action}", as: :json
      assert_equal 404, browser.response.status
    end
  end
end
