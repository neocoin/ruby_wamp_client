=begin

Copyright (c) 2016 Eric Chapman

MIT License

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=end

require 'websocket-eventmachine-client'
require 'wamp_client/session'
require 'wamp_client/transport'

module WampClient
  class Connection
    attr_accessor :options, :transport, :session

    @reconnect = true

    @open = false
    def is_open?
      @open
    end

    # Called when the connection is established
    @on_connect
    def on_connect(&on_connect)
      @on_connect = on_connect
    end

    # Called when the WAMP session is established
    # @param session [WampClient::Session]
    # @param details [Hash]
    @on_join
    def on_join(&on_join)
      @on_join = on_join
    end

    # Called when the WAMP session presents a challenge
    # @param authmethod [String]
    # @param extra [Hash]
    @on_challenge
    def on_challenge(&on_challenge)
      @on_challenge = on_challenge
    end

    # Called when the WAMP session is terminated
    # @param reason [String] The reason the session left the router
    # @param details [Hash] Object containing information about the left session
    @on_leave
    def on_leave(&on_leave)
      @on_leave = on_leave
    end

    # Called when the connection is terminated
    # @param reason [String] The reason the transport was disconnected
    @on_disconnect
    def on_disconnect(&on_disconnect)
      @on_disconnect = on_disconnect
    end

    # @param options [Hash] The different options to pass to the connection
    # @option options [String] :uri The uri of the WAMP router to connect to
    # @option options [String] :realm The realm to connect to
    # @option options [String,nil] :protocol The protocol (default if wamp.2.json)
    # @option options [String,nil] :authid The id to authenticate with
    # @option options [Array, nil] :authmethods The different auth methods that the client supports
    # @option options [Hash] :headers Custom headers to include during the connection
    # @option options [WampClient::Serializer::Base] :serializer The serializer to use (default is json)
    def initialize(options)
      self.options = options || {}
    end

    # Opens the connection
    def open

      raise RuntimeError, 'The connection is already open' if self.is_open?

      @reconnect = true
      @retry_timer = 1
      @retrying = false

      EM.run do
        # Create the transport
        self._create_transport
      end

    end

    # Closes the connection
    def close

      raise RuntimeError, 'The connection is already closed' unless self.is_open?

      # Leave the session
      @reconnect = false
      session.leave

    end

    def _create_session
      self.session = WampClient::Session.new(self.transport, self.options)

      # Setup session callbacks
      self.session.on_challenge do |authmethod, extra|
        self._finish_retry
        @on_challenge.call(authmethod, extra) if @on_challenge
      end

      self.session.on_join do |details|
        self._finish_retry
        @on_join.call(self.session, details) if @on_join
      end

      self.session.on_leave do |reason, details|

        unless @retrying
          @on_leave.call(reason, details) if @on_leave
        end

        if @reconnect
          # Retry
          self._retry unless @retrying
        else
          # Close the transport
          self.transport.disconnect
        end
      end

      self.session.join(self.options[:realm])
    end

    def _create_transport

      if self.transport
        self.transport.disconnect
        self.transport = nil
      end

      # Initialize the transport
      if self.options[:transport]
        self.transport = self.options[:transport]
      else
        self.transport = WampClient::Transport::WebSocketTransport.new(self.options)
      end

      # Setup transport callbacks
      self.transport.on_open do

        # Call the callback
        @on_connect.call if @on_connect

        # Create the session
        self._create_session

      end

      self.transport.on_close do |reason|
        @open = false

        unless @retrying
          @on_disconnect.call(reason) if @on_disconnect
        end

        # Nil out the session since the transport closed underneath it
        self.session = nil

        if @reconnect
          # Retry
          self._retry unless @retrying
        else
          # Stop the Event Machine
          EM.stop
        end
      end

      @open = true

      self.transport.connect

    end

    def _finish_retry
      @retry_timer = 1
      @retrying = false
    end

    def _retry

      unless self.session and self.session.is_open?
        @retry_timer = 2*@retry_timer unless @retry_timer == 32
        @retrying = true

        self._create_transport

        puts "Attempting Reconnect... Next attempt in #{@retry_timer} seconds"
        EM.add_timer(@retry_timer) {
          self._retry if @retrying
        }
      end

    end

  end
end