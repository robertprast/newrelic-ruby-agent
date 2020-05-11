# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.
# frozen_string_literal: true

if NewRelic::Agent::InfiniteTracing::Config.should_load?

  module NewRelic
    module Agent
      # This lets us peek into the Event Listener to see what events 
      # are subscribed.
      class EventListener
        def still_subscribed event
          return [] if @events[event].nil?
          @events[event].select{|e| e.inspect =~ /infinite_tracing/}
        end
      end

      module InfiniteTracing
        module FakeTraceObserverHelpers

          FAKE_SERVER_PORT = 10_000

          def setup
            NewRelic::Agent.instance.stubs(:start_worker_thread)
            @response_handler = ::NewRelic::Agent::Connect::ResponseHandler.new(
              NewRelic::Agent.instance,
              NewRelic::Agent.config
            )
            @agent = NewRelic::Agent.instance
            @agent.service.agent_id = 666
          end

          def assert_only_one_subscription_notifier
            still_subscribed = NewRelic::Agent.agent.events.still_subscribed(:server_source_configuration_added)
            assert_equal 1, still_subscribed.size
          end

          def teardown
            Connection.reset!
            reset_buffers_and_caches
            assert_only_one_subscription_notifier
          end

          # reset! is not used in production code and only needed for 
          # testing purposes, so its implemented here
          # Must clear the @@instance between tests to ensure 
          # a clean start with each test scenario
          class NewRelic::Agent::InfiniteTracing::Connection
            def self.reset!
              self.reset
              @@instance = nil
            end
          end

          def start_fake_trace_observer_server tracer_class
            @server = FakeTraceObserverServer.new FAKE_SERVER_PORT, tracer_class
            @server.run
          end

          # def start_unimplemented_trace_observer_server
          #   @server = FakeTraceObserverServer.new FAKE_SERVER_PORT, UnimplementedInfiniteTracer
          #   @server.run
          # end

          def restart_fake_trace_observer_server tracer_class=InfiniteTracer
            stop_fake_trace_observer_server
            start_fake_trace_observer_server tracer_class
          end
          
          def stop_fake_trace_observer_server
            return unless @server          
            @server.stop
          end
  
          def localhost_config
            {
              :'distributed_tracing.enabled' => true,
              :'span_events.enabled' => true,
              :'infinite_tracing.trace_observer.host' => "localhost:80",
              :'license_key' => "swiss_cheese"
            }
          end

          def fake_server_config
            {
              :'distributed_tracing.enabled' => true,
              :'span_events.enabled' => true,
              :'infinite_tracing.trace_observer.host' => "localhost",
              :'infinite_tracing.trace_observer.port' => FAKE_SERVER_PORT,
              :'license_key' => "swiss_cheese"
            }
          end

          def fiddlesticks_config
            {
              'agent_run_id' => 'fiddlesticks',
              'agent_config' => { 'transaction_tracer.record_sql' => 'raw' }
            }
          end

          def reconnect_config
            {
              'agent_run_id' => 'shazbat',
              'agent_config' => { 'transaction_tracer.record_sql' => 'raw' }
            }
          end

          # simulates applying a server-side config to the agent instance.
          # the sleep 0.01 allows us to choose whether to join and wait
          # or set it up and continue with test scenario's flow.
          def simulate_connect_to_collector config, delay=0.01
            thread = Thread.new do
              sleep delay 
              NewRelic::Agent.instance.stubs(:connected?).returns(true)
              @response_handler.configure_agent config
            end
            yield thread
          ensure
            thread.kill
            NewRelic::Agent.instance.unstub(:connected?)
          end

          # Used to emulate when a force reconnect
          # happens and a new agent run token is presented.
          def simulate_reconnect_to_collector config
            NewRelic::Agent.instance.stubs(:connected?).returns(true)
            @response_handler.configure_agent config
          end

          def emulate_streaming_with_tracer tracer_class, count, max_buffer_size, &block
            with_config fake_server_config do
              simulate_connect_to_collector fake_server_config do |simulator|
                # starts server and simulated agent connection
                start_fake_trace_observer_server tracer_class
                simulator.join

                # starts client and streams count segments             
                client = Client.new
                segments = []
                count.times do |index|
                  with_segment do |segment|
                    segments << segment
                    client << segment

                    # If you want opportunity to do something after each segment
                    # is pushed, invoke this method with a block and do it.
                    block.call(client, segments) if block_given?
                  end
                end

                # ensures all segments consumed then returns the
                # spans the server saw along with the segments sent
                client.flush
                @server.flush count
                return @server.spans, segments
              end
            end
          ensure
            stop_fake_trace_observer_server
          end

          def emulate_streaming_segments count, max_buffer_size=100_000, &block
            emulate_streaming_with_tracer InfiniteTracer, count, max_buffer_size, &block
          end

          def emulate_streaming_to_unimplemented count, max_buffer_size=100_000, &block
            emulate_streaming_with_tracer UnimplementedInfiniteTracer, count, max_buffer_size, &block
          end

          def emulate_streaming_to_unresponsive_server count, max_buffer_size=100_000, &block
            with_config fake_server_config do
              simulate_connect_to_collector fake_server_config do |simulator|
                # NO SERVER STARTED
                simulator.join

                # starts client and streams count segments             
                client = Client.new
                segments = []
                count.times do |index|
                  with_segment do |segment|
                    segments << segment
                    client << segment

                    # If you want opportunity to do something after each segment
                    # is pushed, invoke this method with a block and do it.
                    block.call(client, segments) if block_given?
                  end
                end

                # ensures all segments consumed then returns the
                # spans the server saw along with the segments sent
                client.flush
                @server.flush count
                return @server.spans, segments
              end
            end
          end

        end
      end
    end
  end

end