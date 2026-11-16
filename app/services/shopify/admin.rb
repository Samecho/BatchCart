module Shopify
  class Admin
    VERSION = "2026-10"
    DRAFT_FIELDS = "id name status updatedAt tags"

    def initialize(shop)
      @shop = shop
    end

    def variants(skus)
      results = Hash.new { |hash, key| hash[key] = [] }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 18
      skus.each_slice(20) do |slice|
        search = slice.map { |sku| "sku:\"#{sku}\"" }.join(" OR ")
        cursor = nil
        loop do
          page = catalog_query(<<~GRAPHQL, { search: search, cursor: cursor }, deadline).fetch("productVariants")
            query BatchCartVariants($search: String!, $cursor: String) {
              productVariants(first: 50, query: $search, after: $cursor) {
                nodes { id sku title product { title } }
                pageInfo { hasNextPage endCursor }
              }
            }
          GRAPHQL
          page.fetch("nodes").each do |variant|
            sku = variant.fetch("sku")
            next unless slice.include?(sku)

            results[sku] << { "id" => variant.fetch("id"), "title" => variant.fetch("product").fetch("title"),
                              "variant" => variant.fetch("title") }
          end
          break unless page.dig("pageInfo", "hasNextPage")
          cursor = page.dig("pageInfo", "endCursor")
        end
      end
      results.transform_values { |variants| variants.uniq { |variant| variant["id"] } }
    end

    def create_draft(order)
      data = order.request_data
      input = {
        email: data.fetch("email"), shippingAddress: data.fetch("address"),
        tags: ["batchcart", order.marker], visibleToCustomer: false,
        lineItems: data.fetch("items").map { |item| { variantId: item.fetch("id"), quantity: item.fetch("quantity") } }
      }
      payload = query(<<~GRAPHQL, { input: input }, mutation: true).fetch("draftOrderCreate")
        mutation BatchCartCreate($input: DraftOrderInput!) {
          draftOrderCreate(input: $input) {
            draftOrder { #{DRAFT_FIELDS} }
            userErrors { field }
          }
        }
      GRAPHQL
      return payload["draftOrder"] if payload&.dig("draftOrder", "id")
      if payload&.fetch("userErrors", [])&.any?
        raise Error.new("shopify_rejected_draft", kind: :rejected)
      end

      raise Error.new("missing_draft_response", kind: :unknown)
    rescue KeyError, TypeError
      raise Error.new("missing_draft_response", kind: :unknown)
    end

    def draft(id)
      query(<<~GRAPHQL, { id: id }).fetch("draftOrder")
        query BatchCartDraft($id: ID!) {
          draftOrder(id: $id) { #{DRAFT_FIELDS} }
        }
      GRAPHQL
    end

    def find_drafts(marker)
      page = query(<<~GRAPHQL, { search: "tag:#{marker}" }).fetch("draftOrders")
        query BatchCartFindDraft($search: String!) {
          draftOrders(first: 10, query: $search) {
            nodes { #{DRAFT_FIELDS} }
            pageInfo { hasNextPage }
          }
        }
      GRAPHQL
      return nil if page.dig("pageInfo", "hasNextPage")

      page.fetch("nodes").select { |draft| draft.fetch("tags").include?(marker) }
    end

    private

    def catalog_query(document, variables, deadline)
      query(document, variables)
    rescue Error => error
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise unless error.code == "shopify_throttled" && error.wait&.positive? && error.wait < remaining

      sleep(error.wait)
      retry
    end

    def query(document, variables, mutation: false)
      unless OAuth.allowed?(@shop.domain) && @shop.connected_at
        raise Error.new("reconnect_shop", kind: :rejected)
      end
      if @shop.api_available_at && @shop.api_available_at > Time.current
        raise Error.new("shopify_throttled", kind: :retry_later, wait: @shop.api_available_at - Time.current)
      end
      OAuth.refresh(@shop) if @shop.token_expires_at && @shop.token_expires_at <= 1.minute.from_now
      raise Error.new("reconnect_shop", kind: :rejected) if @shop.access_token.blank?

      execute(document, variables, mutation: mutation)
    end

    def execute(document, variables, mutation:)
      response = Transport.post(@shop.domain, "/admin/api/#{VERSION}/graphql.json",
                                { query: document, variables: variables },
                                { "X-Shopify-Access-Token" => @shop.access_token })
      id = response["x-request-id"]
      Rails.logger.info("shopify shop_id=#{@shop.id} request_id=#{id} http_status=#{response.code}")
      case response.code.to_i
      when 401, 403
        raise Error.new("shopify_permission", kind: :rejected, request_id: id)
      when 429
        throttle([response["retry-after"].to_i, 2].max, id)
      when 200
        body = JSON.parse(response.body)
        wait = rate_wait(body.dig("extensions", "cost"))
        @shop.update!(api_available_at: Time.current + wait) if wait.positive?
        data = body["data"]
        errors = body.fetch("errors", [])
        return data if errors.empty? && data.is_a?(Hash)
        return data if mutation && data&.dig("draftOrderCreate", "draftOrder", "id")

        codes = errors.map { |error| error.dig("extensions", "code") }
        if data.nil? && codes.any? && codes.all?("THROTTLED")
          throttle([wait, 2].max, id)
        end
        no_payload = data.nil? || (mutation && data == { "draftOrderCreate" => nil })
        if no_payload && codes.any? && codes.all?("ACCESS_DENIED") && errors.all? { |error| Array(error["path"]).size <= 1 }
          raise Error.new("shopify_permission", kind: :rejected, request_id: id)
        end
      end

      raise Error.new("shopify_unconfirmed_response", kind: mutation ? :unknown : :retry_later, request_id: id)
    rescue *Transport::NETWORK_ERRORS, JSON::ParserError
      raise Error.new("shopify_transport", kind: mutation ? :unknown : :retry_later)
    end

    def rate_wait(cost)
      throttle = cost&.fetch("throttleStatus", nil)
      return 0 unless throttle && throttle["restoreRate"].to_f.positive?

      required = [cost["requestedQueryCost"].to_i, 15].max
      [(required - throttle["currentlyAvailable"].to_i) / throttle["restoreRate"].to_f, 0].max.ceil
    end

    def throttle(wait, id)
      @shop.update!(api_available_at: Time.current + wait)
      raise Error.new("shopify_throttled", kind: :retry_later, wait: wait, request_id: id)
    end
  end
end
