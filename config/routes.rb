Rails.application.routes.draw do
  root "workspace#show"
  get "/batches/:id", to: "workspace#show", constraints: { id: /\d+/ }
  get "/up", to: "rails/health#show"

  post "/auth/shopify", to: "connections#create"
  get "/auth/shopify/callback", to: "connections#callback"
  post "/auth/demo", to: "connections#demo"
  delete "/session", to: "connections#destroy"
  post "/webhooks/shopify", to: "webhooks#create"

  namespace :api do
    resources :batches, only: [:index, :show, :create] do
      member do
        post :revise
        post :confirm
        post :pause
        post :resume
        get :export
      end
      resources :orders, only: [], controller: "batch_orders" do
        member do
          post :retry
          post :reconcile
          post :close
        end
      end
    end
  end
end
