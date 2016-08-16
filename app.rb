require 'shopify_api'
require 'sinatra'
require 'httparty'
require 'dotenv'

class GiftBasket < Sinatra::Base

  def initialize
    Dotenv.load
    @key = ENV['API_KEY']
    @secret = ENV['API_SECRET']
    @app_url = "jordo.ngrok.io"
    @tokens = {}
    super
  end

  get '/giftbasket/install' do
    shop = request.params['shop']
    scopes = "read_orders,read_products,write_products"

    # construct the installation URL and redirect the merchant
    install_url = "http://#{shop}/admin/oauth/authorize?client_id=#{@key}"\
                "&scope=#{scopes}&redirect_uri=https://#{@app_url}/giftbasket/auth"

    redirect install_url
  end

  get '/giftbasket/auth' do
    # extract shop data from request parameters
    shop = request.params['shop']
    code = request.params['code']
    hmac = request.params['hmac']

    # perform hmac validation to determine if the request is coming from Shopify
    h = request.params.reject{|k,_| k == 'hmac' || k == 'signature'}
    query = URI.escape(h.sort.collect{|k,v| "#{k}=#{v}"}.join('&'))
    digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret, query)

    if not (hmac == digest)
      return [403, "Authentication failed. Digest provided was: #{digest}"]
    end

    # if we don't have an access token for this particular shop,
    # we'll post the OAuth request and receive the token in the response
    if @tokens[shop].nil?
      url = "https://#{shop}/admin/oauth/access_token"

      payload = {
        client_id: @key,
        client_secret: @secret,
        code: code}

      response = HTTParty.post(url, body: payload)

      # if the response is successful, obtain the token and store it in a hash
      if response.code == 200
        @tokens[shop] = response['access_token']
      else
        return [500, "Something went wrong."]
      end

      # now that we have the token, we can instantiate a session
      session = ShopifyAPI::Session.new(shop, @tokens[shop])
      ShopifyAPI::Base.activate_session(session)
    end

    # now that the session is activated, we can create a recurring application charge
    create_recurring_application_charge

    # we want to redirect to the bulk edit URL if there is a token and an activated session
    redirect bulk_edit_url
  end

  get '/activatecharge' do
    # store the charge_id from the request
    charge_id  = request.params['charge_id']
    recurring_application_charge = ShopifyAPI::RecurringApplicationCharge.find(charge_id)
    recurring_application_charge.status == "accepted" ? recurring_application_charge.activate : "Please accept the charge"

    # once the charge is activated, we can subscribe to the order/create webhook and redirect the user back to the bulk edit URL
    create_order_webhook
    redirect bulk_edit_url
  end


  helpers do
    def verify_webhook(hmac, data)
      digest = OpenSSL::Digest.new('sha256')
      calculated_hmac = Base64.encode64(OpenSSL::HMAC.digest(digest, @secret, data)).strip

      hmac == calculated_hmac
    end

    def create_recurring_application_charge
      # checks to see if there is already an RecurringApplicationCharge created and activated
      if not ShopifyAPI::RecurringApplicationCharge.current
        @recurring_application_charge = ShopifyAPI::RecurringApplicationCharge.new(
                name: "Gift Basket Plan",
                price: 4.99,
                return_url: "https:\/\/jordo.ngrok.io\/activatecharge",
                test: true,
                capped_amount: 100,
                terms: "$1 for every order created")

        # if the new RecurringApplicationCharge saves, we redirect to the confirmation URL
        if @recurring_application_charge.save
            redirect @recurring_application_charge.confirmation_url
        end
      end
    end

    def bulk_edit_url
      bulk_edit_url = "https://www.shopify.com/admin/bulk"\
                    "?resource_name=ProductVariant"\
                    "&edit=metafields.test.ingredients:string"
      return bulk_edit_url
    end

    def create_order_webhook
      # create webhook for order creation if it doesn't exist
      if not ShopifyAPI::Webhook.find(:all).any?
        webhook = {
          topic: 'orders/create',
          address: "https://#{@app_url}/giftbasket/webhook/order_create",
          format: 'json'}

        ShopifyAPI::Webhook.create(webhook)
      end
    end

    def create_usage_charge
      usage_charge = ShopifyAPI::UsageCharge.new(description: "1 dollar per order plan", price: 1.0)
      recurring_application_charge_id = ShopifyAPI::RecurringApplicationCharge.last
      usage_charge.prefix_options = {recurring_application_charge_id: recurring_application_charge_id.id}
      usage_charge.save
      puts "Usage charge created successfully!"
    end
  end

  post '/giftbasket/webhook/order_create' do
    # inspect hmac value in header and verify webhook
    hmac = request.env['HTTP_X_SHOPIFY_HMAC_SHA256']

    request.body.rewind
    data = request.body.read
    webhook_ok = verify_webhook(hmac, data)

    if webhook_ok
      shop = request.env['HTTP_X_SHOPIFY_SHOP_DOMAIN']
      token = @tokens[shop]

      if not token.nil?
        session = ShopifyAPI::Session.new(shop, token)
        ShopifyAPI::Base.activate_session(session)
      else
        return [403, "You're not authorized to perform this action."]
      end
    else
      return [403, "You're not authorized to perform this action."]
    end

    # charge fee with the UsageCharge endpoint
    create_usage_charge

    # parse the request body as JSON data
    json_data = JSON.parse data

    line_items = json_data['line_items']

    line_items.each do |line_item|
      variant_id = line_item['variant_id']

      variant = ShopifyAPI::Variant.find(variant_id)

      variant.metafields.each do |field|
        if field.key == 'ingredients'
          items = field.value.split(',')

          items.each do |item|
            gift_item = ShopifyAPI::Variant.find(item)
            gift_item.inventory_quantity = gift_item.inventory_quantity - 1
            gift_item.save
          end
        end
      end
    end

    return [200, "Webhook notification received successfully."]
  end

end

run GiftBasket.run!
