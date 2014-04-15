# -*- coding: utf-8 -*-
require File.expand_path('../../test_helper', __FILE__)

module Stripe
  class ApiResourceTest < Test::Unit::TestCase
    should "creating a new APIResource should not fetch over the network" do
      Stripe.expects(:execute_request).with(has_entry(:method => :get)).never
      Stripe::Customer.new("someid")
    end

    should "creating a new APIResource from a hash should not fetch over the network" do
      Stripe.expects(:execute_request).with(has_entry(:method => :get)).never
      Stripe::Customer.construct_from({
        :id => "somecustomer",
        :card => {:id => "somecard", :object => "card"},
        :object => "customer"
      })
    end

    should "setting an attribute should not cause a network request" do
      Stripe.expects(:execute_request).never
      c = Stripe::Customer.new("test_customer");
      c.card = {:id => "somecard", :object => "card"}
    end

    should "accessing id should not issue a fetch" do
      Stripe.expects(:execute_request).never
      c = Stripe::Customer.new("test_customer")
      c.id
    end

    should "not specifying api credentials should raise an exception" do
      Stripe.api_key = nil
      assert_raises Stripe::AuthenticationError do
        Stripe::Customer.new("test_customer").refresh
      end
    end

    should "specifying api credentials containing whitespace should raise an exception" do
      Stripe.api_key = "key "
      assert_raises Stripe::AuthenticationError do
        Stripe::Customer.new("test_customer").refresh
      end
    end

    should "specifying invalid api credentials should raise an exception" do
      Stripe.api_key = "invalid"
      assert_raises Stripe::AuthenticationError do
        Stripe::Customer.retrieve("failing_customer")
      end
    end

    should "AuthenticationErrors should have an http status, http body, and JSON body" do
      Stripe.api_key = "invalid"

      begin
        VCR.use_cassette('api_resource/auth_errors') do
          Stripe::Customer.retrieve("failing_customer")
        end
      rescue Stripe::AuthenticationError => e
        assert_equal(401, e.http_status)
        assert_equal(true, !!e.http_body)
        assert_equal(true, !!e.json_body[:error][:message])
        assert_match test_invalid_api_key_error['error']['message'], e.json_body[:error][:message]
      end
    end

    context "when specifying per-object credentials" do
      context "with no global API key set" do
        should "use the per-object credential when creating" do
          Stripe.expects(:execute_request).with do |opts|
            opts[:headers][:authorization] == 'Bearer sk_test_local'
          end.returns(test_response(test_charge))

          Stripe::Charge.create({:card => {:number => '4242424242424242'}},
            'sk_test_local')
        end
      end

      context "with a global API key set" do
        setup do
          Stripe.api_key = "global"
        end

        teardown do
          Stripe.api_key = nil
        end

        should "use the per-object credential when creating" do
          Stripe.expects(:execute_request).with do |opts|
            opts[:headers][:authorization] == 'Bearer local'
          end.returns(test_response(test_charge))

          Stripe::Charge.create({:card => {:number => '4242424242424242'}},
            'local')
        end

        should "use the per-object credential when retrieving and making other calls" do
          Stripe.expects(:execute_request).with do |opts|
            opts[:url] == "#{Stripe.api_base}/v1/charges/ch_test_charge" &&
              opts[:headers][:authorization] == 'Bearer local'
          end.returns(test_response(test_charge))
          Stripe.expects(:execute_request).with do |opts|
            opts[:url] == "#{Stripe.api_base}/v1/charges/ch_test_charge/refund" &&
              opts[:headers][:authorization] == 'Bearer local'
          end.returns(test_response(test_charge))

          ch = Stripe::Charge.retrieve('ch_test_charge', 'local')
          ch.refund
        end
      end
    end

    context "with valid credentials" do

      setup do
        VCR.use_cassette('api_resource/create_test_customer') do
          @customer = Stripe::Customer.create({:email => Faker::Internet.email})
        end
      end

      teardown do
        VCR.use_cassette('api_resource/delete_test_customer') do
          # If this method is stubbed, revive it.
          Stripe.unstub(:execute_request)
          @customer.delete
        end
      end

      should "construct URL properly with base query parameters" do
        response = test_response(test_invoice_customer_array(@customer.id))
        customer_invoices_url = "#{Stripe.api_base}/v1/invoices?customer=#{@customer.id}"
        paid_customer_invoices_url = "#{customer_invoices_url}&paid=true"

        Stripe.expects(:execute_request).
          with(has_value(customer_invoices_url)).
          returns(response)
        invoices = Stripe::Invoice.all(:customer => @customer.id)

        Stripe.expects(:execute_request).
          with(has_value(paid_customer_invoices_url)).
          returns(response)
        invoices.all(:paid => true)
      end


      should "setting a nil value for a param should exclude that param from the request" do
        Stripe.expects(:execute_request).with do |request_options|
          puts request_options.inspect
          url = request_options[:url]
          query = CGI.parse(URI.parse(url))
          (url =~ %r{^#{Stripe.api_base}/v1/charges?} &&
           query.keys.sort == ['offset', 'sad'])
        end.returns(test_response({ :count => 1, :data => [test_charge] }))
        Stripe::Charge.all(:count => nil, :offset => 5, :sad => false)

        Stripe.expects(:execute_request).with do |request_options|
          params = CGI.parse request_options[:payload]
          request_options[:url] == "#{Stripe.api_base}/v1/charges" &&
            api_key.nil? &&
            params == { 'amount' => ['50'], 'currency' => ['usd'] }
        end.returns(test_response({ :count => 1, :data => [test_charge] }))
        Stripe::Charge.create(:amount => 50, :currency => 'usd', :card => { :number => nil })
      end

      should "requesting with a unicode ID should result in a request" do
        VCR.use_cassette('api_resource/request_with_unicode_id') do
          c = Stripe::Customer.new("☃")
          assert_raises(Stripe::InvalidRequestError) { c.refresh }
        end
      end

      should "requesting with no ID should result in an InvalidRequestError with no request" do
        c = Stripe::Customer.new
        assert_raises(Stripe::InvalidRequestError) { c.refresh }
      end

      should "making a GET request with parameters should have a query string and no body" do
        params = { :limit => 1 }
        Stripe.expects(:execute_request).once.with do |request_options|
          request_options[:url] == "#{Stripe.api_base}/v1/charges?limit=1"
        end.returns(test_response([test_charge]))
        Stripe::Charge.all(params)
      end

      should "making a POST request with parameters should have a body and no query string" do
        params = { :amount => 100, :currency => 'usd', :card => 'sc_token' }
        Stripe.expects(:execute_request).once.with do |request_options|
          post_params = CGI.parse(request_options[:payload])
          uri = URI.parse request_options[:url]
          uri.query.nil? && post_params == {'amount' => ['100'], 'currency' => ['usd'], 'card' => ['sc_token']}
        end.returns(test_response(test_charge))
        Stripe::Charge.create(params)
      end

      should "loading an object should issue a GET request" do
        VCR.use_cassette('api_resource/loading_object') do
          c = Stripe::Customer.new(@customer.id)
          c.refresh
        end
      end

      should "using array accessors should be the same as the method interface" do
        @customer.refresh
        assert_equal @customer.created, @customer[:created]
        assert_equal @customer.created, @customer['created']
        @customer['created'] = 12345
        assert_equal @customer.created, 12345
      end

      should "accessing a property other than id or parent on an unfetched object should fetch it" do
        Stripe.expects(:execute_request).returns(test_response(test_charge_array))
        @customer.charges
      end

      should "updating an object should issue a POST request with only the changed properties" do
        VCR.use_cassette('api_resource/post_only_changed_properties') do
          c = Stripe::Customer.construct_from(@customer)
          c.description = "another_mn"


          Stripe.expects(:execute_request).with do |request_options|
            (
              request_options[:url] == "#{Stripe.api_base}/v1/customers/#{@customer.id}" &&
                request_options[:api_key].nil? &&
                CGI.parse(request_options[:payload]) == {'description' => ['another_mn']}
            )
          end.once.returns(test_response(test_customer))

          c.save
        end
      end

      should "updating should merge in returned properties" do
        VCR.use_cassette('api_resource/updating_should_merge_props') do
          c = Stripe::Customer.new(@customer.id)
          new_description = "another customer"
          c.description = new_description
          c.save

          assert_equal new_description, c.description
        end
      end

      should "deleting should send no props and result in an object that has no props other deleted" do
        c = Stripe::Customer.construct_from(@customer)

        Stripe.expects(:execute_request).with do |request_options|
          request_options[:url] == "#{Stripe.api_base}/v1/customers/#{@customer.id}"
        end.once.returns(test_response({ "id" => @customer.id, "deleted" => true }))

        c.delete
        assert_equal true, c.deleted

        assert_raises NoMethodError do
          c.livemode
        end
      end

      should "loading an object with properties that have specific types should instantiate those classes" do
        @mock.expects(:get).once.returns(test_response(test_charge))
        VCR.use_cassette('api_resource/object_instantiation') do
          c = Stripe::Customer.retrieve(@customer.id)
          assert c.card.kind_of?(Stripe::StripeObject) && c.card.object == 'card'
        end
      end

      should "loading all of an APIResource should return an array of recursively instantiated objects" do
        @mock.expects(:get).once.returns(test_response(test_charge_array))
        c = Stripe::Charge.all.data
        assert c.kind_of? Array
        assert c[0].kind_of? Stripe::Charge
        assert c[0].card.kind_of?(Stripe::StripeObject) && c[0].card.object == 'card'
      end


      context "error checking" do

        should "a 400 should give an InvalidRequestError with http status, body, and JSON body" do
          response = test_response(test_api_error, 400)
          Stripe.expects(:execute_request).once.
            raises(RestClient::ExceptionWithResponse.new(response, 400))

          begin
            Stripe::Customer.retrieve("foo")
          rescue Stripe::InvalidRequestError => e
            assert_equal(400, e.http_status)
            assert_equal(true, !!e.http_body)
            assert_equal(true, e.json_body.kind_of?(Hash))
          end
        end

        should "a 401 should give an AuthenticationError with http status, body, and JSON body" do
          begin
            VCR.use_cassette('api_resource/auth_error_with_details') do
              Stripe::Customer.retrieve("foo", "invalid_key")
            end
          rescue Stripe::AuthenticationError => e
            assert_equal(401, e.http_status)
            assert_equal(true, !!e.http_body)
            assert_equal(true, e.json_body.kind_of?(Hash))
          end
        end

        should "a 402 should give a CardError with http status, body, and JSON body" do
          begin
            VCR.use_cassette('api_resource/card_error_with_details') do
              card_params = {
                :number => '4242424242424242',
                :exp_year => 2000,
                :exp_month => 1
              }
              Stripe::Charge.create({:card => card_params, :amount => 1000, :currency => "usd"})
            end
          rescue Stripe::CardError => e
            assert_equal(402, e.http_status)
            assert_equal(true, !!e.http_body)
            assert_equal(true, e.json_body.kind_of?(Hash))
          end
        end

        should "a 404 should give an InvalidRequestError with http status, body, and JSON body" do
          response = test_response(test_api_error, 404)
          Stripe.expects(:execute_request).once.
            raises(RestClient::ExceptionWithResponse.new(response, 404))

          begin
            Stripe::Customer.retrieve("foo")
          rescue Stripe::InvalidRequestError => e
            assert_equal(404, e.http_status)
            assert_equal(true, !!e.http_body)
            assert_equal(true, e.json_body.kind_of?(Hash))
          end
        end


        should "5XXs should raise an APIError" do
          response = test_response(test_api_error, 500)
          Stripe.expects(:execute_request).once.
            raises(RestClient::ExceptionWithResponse.new(response, 500))

          begin
            Stripe::Customer.new("test_customer").refresh
          rescue Stripe::APIError => e # we don't use assert_raises because we want to examine e
            assert e.kind_of? Stripe::APIError
          end
        end

      end
    end
  end
end
