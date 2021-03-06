require 'test_helper'
require 'stubs/test_connection'
require 'stubs/room'

module ActionCable::StreamTests
  class Connection < ActionCable::Connection::Base
    attr_reader :websocket

    def send_async(method, *args)
      send method, *args
    end
  end

  class ChatChannel < ActionCable::Channel::Base
    def subscribed
      if params[:id]
        @room = Room.new params[:id]
        stream_from "test_room_#{@room.id}", coder: pick_coder(params[:coder])
      end
    end

    def send_confirmation
      transmit_subscription_confirmation
    end

    private def pick_coder(coder)
      case coder
      when nil, 'json'
        ActiveSupport::JSON
      when 'custom'
        DummyEncoder
      when 'none'
        nil
      end
    end
  end

  module DummyEncoder
    extend self
    def encode(*) '{ "foo": "encoded" }' end
    def decode(*) { foo: 'decoded' } end
  end

  class SymbolChannel < ActionCable::Channel::Base
    def subscribed
      stream_from :channel
    end
  end

  class StreamTest < ActionCable::TestCase
    test "streaming start and stop" do
      run_in_eventmachine do
        connection = TestConnection.new
        connection.expects(:pubsub).returns mock().tap { |m| m.expects(:subscribe).with("test_room_1", kind_of(Proc), kind_of(Proc)).returns stub_everything(:pubsub) }
        channel = ChatChannel.new connection, "{id: 1}", { id: 1 }

        connection.expects(:pubsub).returns mock().tap { |m| m.expects(:unsubscribe) }
        channel.unsubscribe_from_channel
      end
    end

    test "stream from non-string channel" do
      run_in_eventmachine do
        connection = TestConnection.new
        connection.expects(:pubsub).returns mock().tap { |m| m.expects(:subscribe).with("channel", kind_of(Proc), kind_of(Proc)).returns stub_everything(:pubsub) }
        channel = SymbolChannel.new connection, ""

        connection.expects(:pubsub).returns mock().tap { |m| m.expects(:unsubscribe) }
        channel.unsubscribe_from_channel
      end
    end

    test "stream_for" do
      run_in_eventmachine do
        connection = TestConnection.new
        connection.expects(:pubsub).returns mock().tap { |m| m.expects(:subscribe).with("action_cable:stream_tests:chat:Room#1-Campfire", kind_of(Proc), kind_of(Proc)).returns stub_everything(:pubsub) }

        channel = ChatChannel.new connection, ""
        channel.stream_for Room.new(1)
      end
    end

    test "stream_from subscription confirmation" do
      run_in_eventmachine do
        connection = TestConnection.new

        ChatChannel.new connection, "{id: 1}", { id: 1 }
        assert_nil connection.last_transmission

        wait_for_async

        confirmation = { "identifier" => "{id: 1}", "type" => "confirm_subscription" }
        connection.transmit(confirmation)

        assert_equal confirmation, connection.last_transmission, "Did not receive subscription confirmation within 0.1s"
      end
    end

    test "subscription confirmation should only be sent out once" do
      run_in_eventmachine do
        connection = TestConnection.new

        channel = ChatChannel.new connection, "test_channel"
        channel.send_confirmation
        channel.send_confirmation

        wait_for_async

        expected = { "identifier" => "test_channel", "type" => "confirm_subscription" }
        assert_equal expected, connection.last_transmission, "Did not receive subscription confirmation"

        assert_equal 1, connection.transmissions.size
      end
    end
  end

  require 'action_cable/subscription_adapter/inline'

  class StreamEncodingTest < ActionCable::TestCase
    setup do
      @server = TestServer.new(subscription_adapter: ActionCable::SubscriptionAdapter::Inline)
      @server.config.allowed_request_origins = %w( http://rubyonrails.com )
      @server.stubs(:channel_classes).returns(ChatChannel.name => ChatChannel)
    end

    test 'custom encoder' do
      run_in_eventmachine do
        connection = open_connection
        subscribe_to connection, identifiers: { id: 1 }

        connection.websocket.expects(:transmit)
        @server.broadcast 'test_room_1', { foo: 'bar' }, coder: DummyEncoder
        wait_for_async
      end
    end

    private
      def subscribe_to(connection, identifiers:)
        receive connection, command: 'subscribe', identifiers: identifiers
      end

      def open_connection
        env = Rack::MockRequest.env_for '/test', 'HTTP_HOST' => 'localhost', 'HTTP_CONNECTION' => 'upgrade', 'HTTP_UPGRADE' => 'websocket', 'HTTP_ORIGIN' => 'http://rubyonrails.com'

        Connection.new(@server, env).tap do |connection|
          connection.process
          assert connection.websocket.possible?

          wait_for_async
          assert connection.websocket.alive?
        end
      end

      def receive(connection, command:, identifiers:)
        identifier = JSON.generate(channel: 'ActionCable::StreamTests::ChatChannel', **identifiers)
        connection.dispatch_websocket_message JSON.generate(command: command, identifier: identifier)
        wait_for_async
      end
  end
end
