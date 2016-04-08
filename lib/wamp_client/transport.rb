require 'wamp_client/serializer'

module WampClient
  module Transport
    class Base

      # Callback when the socket is opened
      attr_accessor :on_open

      # Callback when the socket is closed.  Parameters are
      # @param reason [String] String telling the reason it was closed
      attr_accessor :on_close

      # Callback when a message is received.  Parameters are
      # @param msg [Array] The parsed message that was received
      attr_accessor :on_message

      # Callback when there is an error.  Parameters are
      attr_accessor :on_error

      attr_accessor :type, :uri, :headers, :protocol, :serializer, :connected

      # Constructor for the transport
      # @param options [Hash] The connection options.  the different options are as follows
      # @option options [String] :uri The url to connect to
      # @option options [String] :protocol The protocol
      # @option options [Hash] :headers Custom headers to include during the connection
      # @option options [WampClient::Serializer::Base] :serializer The serializer to use
      def initialize(options)

        # Initialize the parameters
        self.connected = false
        self.uri = options[:uri]
        self.headers = options[:headers] || {}
        self.protocol = options[:protocol] || 'wamp.2.json'
        self.serializer = options[:serializer] || WampClient::Serializer::JSONSerializer.new

        # Add the wamp.2.json protocol header
        self.headers['Sec-WebSocket-Protocol'] = self.protocol

        # Initialize callbacks
        self.on_open = nil
        self.on_close = nil
        self.on_message = nil
        self.on_error = nil

      end

      # Connects to the WAMP Server using the transport
      def connect
        # Implement in subclass
      end

      # Disconnects from the WAMP Server
      def disconnect
        # Implement in subclass
      end

      # Returns true if the transport it connected
      def connected?
        self.connected
      end

      # Sends a Message
      # @param [Array] msg - The message payload to send
      def send_message(msg)
        # Implement in subclass
      end

    end

    # This implementation uses the 'websocket-eventmachine-client' Gem.  This is the default if no transport is included
    class WebSocketTransport < Base
      attr_accessor :socket

      def initialize(options)
        super(options)
        self.type = 'websocket'
        self.socket = nil
      end

      def connect
        self.socket = WebSocket::EventMachine::Client.connect(
            :uri => @uri,
            :headers => @headers
        )

        self.socket.onopen do
          self.connected = true
          self.on_open.call unless self.on_open.nil?
        end

        self.socket.onmessage do |msg, type|
          self.on_message.call(self.serializer.deserialize(msg)) unless self.on_message.nil?
        end

        self.socket.onclose do |code, reason|
          self.connected = false
          self.on_close.call(reason) unless self.on_close.nil?
        end
      end

      def disconnect
        self.connected = !self.socket.close  # close returns 'true' if the connection was closed immediately
      end

      def send_message(msg)
        if self.connected
          self.socket.send(self.serializer.serialize(msg), {type: 'text'})
        else
          raise RuntimeError, "Socket must be open to call 'send_message'"
        end
      end

    end
  end
end