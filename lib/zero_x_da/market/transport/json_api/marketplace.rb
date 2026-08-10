# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module MarketplaceEndpoints
          def initialize(marketplace: nil, **options)
            @marketplace = marketplace
            super(**options)
          end

          def available?(endpoint)
            return !@marketplace.nil? if endpoint == :marketplace

            super
          end

          def create_marketplace_quote(request)
            body = @request_parser.request_document(request)
            result = @marketplace.quote(
              customer_user_id: body.fetch("actor_user_id"),
              sku: body.fetch("sku"),
              quantity: body.fetch("quantity", 1),
              recipient: body["recipient"],
              context: body.fetch("context", {})
            )
            resource_response(201, present_marketplace_quote(result))
          end

          def accept_marketplace_quote(request, id:)
            body = @request_parser.request_document(request)
            result = @marketplace.accept(
              customer_user_id: body.fetch("actor_user_id"),
              quote_id: id
            )
            resource_response(201, present_marketplace_order(result))
          end

          def find_marketplace_order(request, id:)
            result = @marketplace.find_order(
              customer_user_id: request.params.fetch("actor_user_id"),
              order_id: id
            )
            resource_response(200, present_marketplace_order(result))
          end

          def confirm_marketplace_payment(request, id:)
            body = @request_parser.request_document(request)
            result = @marketplace.confirm_customer_payment(
              customer_user_id: body.fetch("actor_user_id"),
              order_id: id,
              reference: body.fetch("reference"),
              provider: body.fetch("provider"),
              amount: body.fetch("amount"),
              currency: body.fetch("currency"),
              data: body.fetch("data", {})
            )
            resource_response(200, present_marketplace_order(result))
          end

          def execute_marketplace_order(request, id:)
            body = @request_parser.request_document(request)
            result = @marketplace.execute_order(
              customer_user_id: body.fetch("actor_user_id"),
              order_id: id
            )
            resource_response(200, present_marketplace_order(result))
          end

          private

          def present_marketplace_quote(result)
            resource = present_quote(result.quote)
            resource.fetch("attributes").merge!(
              "product_sku" => result.product.sku,
              "quantity" => decimal_string(result.reservation.quantity),
              "unit_price_usdt" => decimal_string(result.unit_price_usdt),
              "total_price_usdt" => decimal_string(result.total_price_usdt),
              "currency" => "USDT",
              "inventory_status" => result.reservation.status,
              "recipient" => result.recipient&.to_h
            ).compact!
            resource
          end

          def present_marketplace_order(result)
            resource = present_order(result.order)
            resource.fetch("attributes").merge!(
              "quantity" => decimal_string(result.reservation.quantity),
              "inventory_status" => result.reservation.status,
              "payment_status" => result.order.payment&.fetch("status", nil) || "not_required",
              "payment" => result.order.payment,
              "recipient" => result.order.payload["recipient"]
            ).compact!
            resource
          end
        end

        module MarketplaceRoutes
          private

          def resolve(request)
            method = request.request_method
            path = request.path_info

            if method == "POST" && path == "/v1/market/quotes" && available?(:marketplace)
              return route(:create_marketplace_quote)
            end

            quote_match = path.match(%r{\A/v1/market/quotes/([^/]+)/accept\z})
            if method == "POST" && quote_match && available?(:marketplace)
              return route(:accept_marketplace_quote, id: quote_match[1])
            end

            payment_match = path.match(%r{\A/v1/market/orders/([^/]+)/payment/confirm\z})
            if method == "POST" && payment_match && available?(:marketplace)
              return route(:confirm_marketplace_payment, id: payment_match[1])
            end

            order_match = path.match(%r{\A/v1/market/orders/([^/]+)\z})
            if method == "GET" && order_match && available?(:marketplace)
              return route(:find_marketplace_order, id: order_match[1])
            end

            execution_match = path.match(%r{\A/v1/market/orders/([^/]+)/execute\z})
            if method == "POST" && execution_match && available?(:marketplace)
              return route(:execute_marketplace_order, id: execution_match[1])
            end

            super
          end
        end

        EndpointHandler.prepend(MarketplaceEndpoints)
        Router.prepend(MarketplaceRoutes)
      end
    end
  end
end
