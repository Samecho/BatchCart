require "test_helper"

class ShopifyOAuthTest < ActiveSupport::TestCase
  test "offline grants and refresh use form requests and save the rotated token pair" do
    store = shop("oauth-sample.myshopify.com")
    calls = []
    transport = lambda do |domain, path, body, form:|
      assert_equal store.domain, domain
      assert_equal "/admin/oauth/access_token", path
      assert form
      calls << body
      shopify_reply(200, { access_token: "access-#{calls.size}", refresh_token: "refresh-#{calls.size}", expires_in: 3600 })
    end

    with_config(SHOPIFY_CLIENT_ID: "fake-client", SHOPIFY_CLIENT_SECRET: "fake-secret") do
      Shopify::Transport.stub(:post, transport) do
        token = Shopify::OAuth.exchange(store.domain, "fake-code", online: false)
        Shopify::OAuth.save_token(store, token)
        Shopify::OAuth.refresh(store)
      end
    end

    assert_equal ["fake-code", 1], calls.first.values_at(:code, :expiring)
    assert_equal ["refresh_token", "refresh-1"], calls.last.values_at(:grant_type, :refresh_token)
    assert_equal ["access-2", "refresh-2"], store.reload.attributes.values_at("access_token", "refresh_token")
    assert store.token_expires_at.future?
  end
end
