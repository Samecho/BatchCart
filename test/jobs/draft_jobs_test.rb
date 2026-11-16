require "test_helper"

class DraftJobsTest < ActiveSupport::TestCase
  test "a paused batch keeps pending orders and resumes without recreating completed drafts" do
    store = shop
    batch = confirmed(store, limit: 3)
    demo = Shopify::Demo.new(store)
    client = Object.new
    client.define_singleton_method(:create_draft) do |order|
      batch.reload.update!(paused_at: Time.current)
      demo.create_draft(order)
    end

    Shopify::Demo.stub(:new, client) { RunShopJob.perform_now(store.id) }
    assert_equal({ "pending" => 1, "succeeded" => 1 }, batch.orders.group(:status).count)
    batch.reload.update!(paused_at: nil)
    RunShopJob.perform_now(store.id)
    assert_equal({ "succeeded" => 2 }, batch.orders.group(:status).count)
    assert_equal 2, DemoDraft.where(shop: store).count
  end

  test "a timeout after creation is reconciled by marker and never replays the mutation" do
    store = shop
    order = confirmed(store).orders.sole
    demo = Shopify::Demo.new(store)
    client = Object.new
    client.define_singleton_method(:create_draft) do |entry|
      demo.create_draft(entry)
      raise Shopify::Error.new("shopify_transport", kind: :unknown)
    end

    Shopify::Demo.stub(:new, client) { RunShopJob.perform_now(store.id) }
    assert_equal "review", order.reload.status
    assert_no_difference("DemoDraft.count") { RunShopJob.perform_now(store.id) }
    SyncShopJob.perform_now(store.id)
    assert_equal "succeeded", order.reload.status
    assert_equal 1, DemoDraft.where(shop: store, marker: order.marker).count
    assert_equal 1, order.attempts
  end

  test "missing Shopify matches stay in review" do
    store = shop
    order = confirmed(store).orders.sole
    order.update!(status: "review", sync_at: 1.second.ago)
    SyncShopJob.perform_now(store.id)
    assert_equal "review", order.reload.status
    assert_equal "draft_not_found", order.error_code
    assert order.sync_at.future?
  end
end

class ConcurrentDraftJobsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "the next worker reconciles a process killed after the remote write" do
    store = shop("interrupted-#{SecureRandom.hex(5)}.myshopify.com")
    demo = Shopify::Demo.new(store)
    order = Shopify::Admin.stub(:new, demo) { confirmed(store).orders.sole }
    pid = fork do
      worker = Object.new
      worker.define_singleton_method(:create_draft) do |entry|
        demo.create_draft(entry)
        Process.kill("KILL", Process.pid)
      end
      Shopify::Admin.stub(:new, worker) { RunShopJob.perform_now(store.id) }
    end
    _, exit_status = Timeout.timeout(8) { Process.wait2(pid) }
    assert_equal Signal.list.fetch("KILL"), exit_status.termsig
    assert_equal "running", order.reload.status
    travel 3.minutes do
      Shopify::Admin.stub(:new, demo) do
        assert_no_difference("DemoDraft.count") { RunShopJob.perform_now(store.id) }
        assert_equal "review", order.reload.status
        SyncShopJob.perform_now(store.id)
        assert_equal "succeeded", order.reload.status
      end
    end
  end

  test "duplicate jobs on separate database connections send one mutation" do
    first = second = nil
    store = shop("concurrency-#{SecureRandom.hex(5)}.myshopify.com")
    demo = Shopify::Demo.new(store)
    entered = Queue.new
    release = Queue.new
    client = Object.new
    client.define_singleton_method(:variants) { |skus| demo.variants(skus) }
    client.define_singleton_method(:create_draft) do |entry|
      entered.push(true)
      release.pop
      demo.create_draft(entry)
    end

    Shopify::Admin.stub(:new, client) do
      order = confirmed(store).orders.sole
      first = Thread.new { Rails.application.executor.wrap { RunShopJob.perform_now(store.id) } }
      Timeout.timeout(5) { entered.pop }
      second = Thread.new { Rails.application.executor.wrap { RunShopJob.perform_now(store.id) } }
      assert second.join(5), "The competing worker should skip a shop already in use"
      assert_equal "running", order.reload.status
      release.push(true)
      assert first.join(5)
      assert_equal "succeeded", order.reload.status
      assert_equal 1, DemoDraft.where(shop: store, marker: order.marker).count
    end
  ensure
    release&.push(true)
    second&.join(5)
    first&.join(5)
  end
end
