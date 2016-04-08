require 'wamp_client/transport'
require 'wamp_client/message'
require 'wamp_client/check'

module WampClient

  WAMP_FEATURES = {
      caller: {
          features: {
              # caller_identification: true,
              ##call_timeout: true,
              ##call_canceling: true,
              # progressive_call_results: true
          }
      },
      callee: {
          features: {
              # caller_identification: true,
              ##call_trustlevels: true,
              # pattern_based_registration: true,
              # shared_registration: true,
              ##call_timeout: true,
              ##call_canceling: true,
              # progressive_call_results: true,
              # registration_revocation: true
          }
      },
      publisher: {
          features: {
              # publisher_identification: true,
              # subscriber_blackwhite_listing: true,
              # publisher_exclusion: true
          }
      },
      subscriber: {
          features: {
              # publisher_identification: true,
              ##publication_trustlevels: true,
              # pattern_based_subscription: true,
              # subscription_revocation: true
              ##event_history: true,
          }
      }
  }

  class Subscription
    attr_accessor :topic, :handler, :options, :session, :id

    def initialize(topic, handler, options, session, id)
      self.topic = topic
      self.handler = handler
      self.options = options
      self.session = session
      self.id = id
    end

    def unsubscribe
      self.session.unsubscribe(self)
    end

  end

  class Session
    include WampClient::Check

    # on_join callback is called when the session joins the router.  It has the following parameters
    # @param details [Hash] Object containing information about the joined session
    attr_accessor :on_join

    # on_leave callback is called when the session leaves the router.  It has the following attributes
    # @param reason [String] The reason the session left the router
    # @param details [Hash] Object containing information about the left session
    attr_accessor :on_leave

    attr_accessor :id, :realm, :transport

    # Private attributes
    attr_accessor :_goodbye_sent, :_requests, :_subscriptions, :_registrations

    # Constructor
    # @param transport [WampClient::Transport::Base] The transport that the session will use
    def initialize(transport)

      # Parameters
      self.id = nil
      self.realm = nil

      # Outstanding Requests
      self._requests = {
          publish: {},
          subscribe: {},
          unsubscribe: {},
          call: {},
          register: {},
          unregister: {}
      }

      # Init Subs and Regs in place
      self._subscriptions = {}
      self._registrations = {}

      # Setup Transport
      self.transport = transport
      self.transport.on_message = lambda do |msg|
        self._process_message(msg)
      end

      # Other parameters
      self._goodbye_sent = false

      # Setup session callbacks
      self.on_join = nil
      self.on_leave = nil

    end

    # Returns 'true' if the session is open
    def is_open?
      !self.id.nil?
    end

    # Joins the WAMP Router
    # @param realm [String] The name of the realm
    def join(realm)
      if is_open?
        raise RuntimeError, "Session must be closed to call 'join'"
      end

      self.class.check_uri('realm', realm)

      self.realm = realm

      details = {}
      details[:roles] = WAMP_FEATURES

      # Send Hello message
      hello = WampClient::Message::Hello.new(realm, details)
      self.transport.send_message(hello.payload)
    end

    # Leaves the WAMP Router
    # @param reason [String] URI signalling the reason for leaving
    def leave(reason='wamp.close.normal', message=nil)
      unless is_open?
        raise RuntimeError, "Session must be opened to call 'leave'"
      end

      self.class.check_uri('reason', reason, true)
      self.class.check_string('message', message, true)

      details = {}
      details[:message] = message

      # Send Goodbye message
      goodbye = WampClient::Message::Goodbye.new(details, reason)
      self.transport.send_message(goodbye.payload)
      self._goodbye_sent = true
    end

    # Generates an ID according to the specification (Section 5.1.2)
    def _generate_id
      rand(0..9007199254740992)
    end

    # Processes received messages
    def _process_message(msg)
      puts msg

      message = WampClient::Message::Base.parse(msg)

      # WAMP Session is not open
      if self.id.nil?

        # Parse the welcome message
        if message.is_a? WampClient::Message::Welcome
          self.id = message.session
          self.on_join.call(message.details) unless self.on_join.nil?
        elsif message.is_a? WampClient::Message::Abort
          self.on_leave.call(message.reason, message.details) unless self.on_leave.nil?
        end

      # Wamp Session is open
      else

        # If goodbye, close the session
        if message.is_a? WampClient::Message::Goodbye

          # If we didn't send the goodbye, respond
          unless self._goodbye_sent
            goodbye = WampClient::Message::Goodbye.new({}, 'wamp.error.goodbye_and_out')
            self.transport.send_message(goodbye.payload)
          end

          # Close out session
          self.id = nil
          self.realm = nil
          self._goodbye_sent = false
          self.on_leave.call(message.reason, message.details) unless self.on_leave.nil?

        else

          # Process Errors
          if message.is_a? WampClient::Message::Error
            if message.request_type == WampClient::Message::Types.SUBSCRIBE
              self._process_SUBSCRIBE_error(message)
            elsif message.request_type == WampClient::Message::Types.UNSUBSCRIBE
              self._process_UNSUBSCRIBE_error(message)
            elsif message.request_type == WampClient::Message::Types.PUBLISH
              self._process_PUBLISH_error(message)
            else
              # TODO: Some Error??  Not Implemented yet
            end

          # Process Messages
          else
            if message.is_a? WampClient::Message::Subscribed
              self._process_SUBSCRIBED(message)
            elsif message.is_a? WampClient::Message::Unsubscribed
              self._process_UNSUBSCRIBED(message)
            elsif message.is_a? WampClient::Message::Published
              self._process_PUBLISHED(message)
            elsif message.is_a? WampClient::Message::Event
              self._process_EVENT(message)
            else
              # TODO: Some Error??  Not Implemented yet
            end
          end

        end
      end

    end

    #region Subscribe Logic

    # Subscribes to a topic
    # @param topic [String] The topic to subscribe to
    # @param handler [lambda] The handler(args, kwargs, details) when an event is received
    # @param options [Hash] The options for the subscription
    # @param callback [lambda] The callback(subscription, error, details) called to signal if the subscription was a success or not
    def subscribe(topic, handler, options={}, callback=nil)
      unless is_open?
        raise RuntimeError, "Session must be open to call 'subscribe'"
      end

      self.class.check_uri('topic', topic)
      self.class.check_dict('options', options)

      # Create a new subscribe request
      request = self._generate_id
      self._requests[:subscribe][request] = {t: topic, h: handler, o: options, c: callback}

      # Send the message
      subscribe = WampClient::Message::Subscribe.new(request, options, topic)
      self.transport.send_message(subscribe.payload)
    end

    # Processes the response to a subscribe request
    # @param msg [WampClient::Message::Subscribed] The response from the subscribe
    def _process_SUBSCRIBED(msg)

      r_id = msg.subscribe_request
      s_id = msg.subscription

      # Remove the pending subscription, add it to the registered ones, and inform the caller
      s = self._requests[:subscribe].delete(r_id)
      if s
        n_s = Subscription.new(s[:t], s[:h], s[:o], self, s_id)
        self._subscriptions[s_id] = n_s
        c = s[:c]
        c.call(n_s, nil, nil) if c
      end

    end

    # Processes an error from a request
    # @param msg [WampClient::Message::Error] The response from the subscribe
    def _process_SUBSCRIBE_error(msg)

      r_id = msg.request_request
      d = msg.details
      e = msg.error

      # Remove the pending subscription and inform the caller of the failure
      s = self._requests[:subscribe].delete(r_id)
      if s
        c = s[:c]
        c.call(s, e, d) if c
      end

    end

    # Processes and event from the broker
    # @param msg [WampClient::Message::Event] An event that was published
    def _process_EVENT(msg)

      s_id = msg.subscribed_subscription
      p_id = msg.published_publication
      details = msg.details || {}
      args = msg.publish_arguments
      kwargs = msg.publish_argumentskw

      details[:publication] = p_id

      s = self._subscriptions[s_id]
      if s
        h = s.handler
        h.call(args, kwargs, details) if h
      end

    end

    #endregion

    #region Unsubscribe Logic

    # Unsubscribes from a subscription
    # @param subscription [Subscription] The subscription object from when the subscription was created
    # @param callback [lambda] The callback(subscription, error, details) called to signal if the subscription was a success or not
    def unsubscribe(subscription, callback=nil)
      unless is_open?
        raise RuntimeError, "Session must be open to call 'unsubscribe'"
      end

      self.class.check_nil('subscription', subscription, false)

      # Create a new unsubscribe request
      request = self._generate_id
      self._requests[:unsubscribe][request] = { s: subscription, c: callback }

      # Send the message
      unsubscribe = WampClient::Message::Unsubscribe.new(request, subscription.id)
      self.transport.send_message(unsubscribe.payload)
    end

    # Processes the response to a subscribe request
    # @param msg [WampClient::Message::Unsubscribed] The response from the unsubscribe
    def _process_UNSUBSCRIBED(msg)

      r_id = msg.unsubscribe_request

      # Remove the pending unsubscription, add it to the registered ones, and inform the caller
      s = self._requests[:unsubscribe].delete(r_id)
      if s
        n_s = s[:s]
        self._subscriptions.delete(n_s.id)
        c = s[:c]
        c.call(n_s, nil, nil) if c
      end

    end


    # Processes an error from a request
    # @param msg [WampClient::Message::Error] The response from the subscribe
    def _process_UNSUBSCRIBE_error(msg)

      r_id = msg.request_request
      d = msg.details
      e = msg.error

      # Remove the pending subscription and inform the caller of the failure
      s = self._requests[:unsubscribe].delete(r_id)
      if s
        c = s[:c]
        c.call(s, e, d) if c
      end

    end

    #endregion

    #region Publish Logic

    # Publishes and event to a topic
    # @param topic [String] The topic to publish the event to
    # @param args [Array] The arguments
    # @param kwargs [Hash] The keyword arguments
    # @param options [Hash] The options for the subscription
    # @param callback [lambda] The callback(publish, error, details) called to signal if the publish was a success or not
    def publish(topic, args=nil, kwargs=nil, options={}, callback=nil)
      unless is_open?
        raise RuntimeError, "Session must be open to call 'publish'"
      end

      self.class.check_uri('topic', topic)
      self.class.check_dict('options', options)
      self.class.check_list('args', args, true)
      self.class.check_dict('kwargs', kwargs, true)

      # Create a new publish request
      request = self._generate_id
      self._requests[:publish][request] = {t: topic, a: args, k: kwargs, o: options, c: callback} if options[:acknowledge]

      # Send the message
      publish = WampClient::Message::Publish.new(request, options, topic, args, kwargs)
      self.transport.send_message(publish.payload)
    end

    # Processes the response to a publish request
    # @param msg [WampClient::Message::Published] The response from the subscribe
    def _process_PUBLISHED(msg)

      r_id = msg.publish_request
      p_id = msg.publication

      # Remove the pending publish and alert the callback
      s = self._requests[:publish].delete(r_id)
      if s
        c = s[:c]
        c.call(s, nil, {publication: p_id}) if c
      end

    end

    # Processes an error from a publish request
    # @param msg [WampClient::Message::Error] The response from the subscribe
    def _process_PUBLISH_error(msg)

      r_id = msg.request_request
      d = msg.details
      e = msg.error

      # Remove the pending publish and inform the caller of the failure
      s = self._requests[:publish].delete(r_id)
      if s
        c = s[:c]
        c.call(s, e, d) if c
      end

    end

    #endregion

  end
end