module Shopify
  class Demo
    CATALOG = {
      "GIFT-MUG" => { "id" => "demo-mug", "title" => "Camp mug", "variant" => "Cream" },
      "GIFT-TEE" => { "id" => "demo-tee", "title" => "Fundraiser tee", "variant" => "Medium" },
      "GIFT-NOTE" => { "id" => "demo-note", "title" => "Note card", "variant" => "Plain" }
    }.freeze

    def initialize(shop)
      @drafts = DemoDraft.where(shop: shop)
    end

    def variants(skus)
      CATALOG.slice(*skus).transform_values { |variant| [variant] }
    end

    def create_draft(order)
      @drafts.create!(marker: order.marker).to_remote
    end

    def draft(id)
      @drafts.find_by(id: id.split("/").last)&.to_remote
    end

    def find_drafts(marker)
      @drafts.where(marker: marker).map(&:to_remote)
    end
  end
end
