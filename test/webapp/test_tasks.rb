require 'minitest/spec'
require 'rack/test'
require 'orocos'
require 'orocos/test'
require 'orocos/webapp'
require 'rack'
require 'minitest/em_sync'

describe Orocos::WebApp::Tasks do
    include Orocos::Spec
    include Rack::Test::Methods

    before do
        Orocos::CORBA.name_service.ip = 'localhost'
        if !Orocos.initialized?
            Orocos.initialize
        end
    end

    def app
        @app ||= Orocos::WebApp::Root.new
    end

    def with_stub_task_context(task_name)
        ruby_task = Orocos::RubyTaskContext.new task_name
        yield(ruby_task)
    ensure
        ruby_task.dispose if ruby_task
    end

    describe "/tasks" do
        describe "GET /" do
            it "returns an empty array" do
                get "/tasks"
                assert_equal 200, last_response.status
                assert_equal Hash['task_names' => []], MultiJson.load(last_response.body)
            end

            describe "extended_info" do
                it "returns an empty array" do
                    get "/tasks?extended_info=true"
                    assert_equal 200, last_response.status
                    assert_equal Hash['tasks' => []], MultiJson.load(last_response.body)
                end

                it "returns the name and model name of a given task" do
                    with_stub_task_context "task" do |task|
                        get "/tasks?extended_info=true"
                        assert_equal 200, last_response.status
                        expected = Hash[name: 'localhost/task', model: Hash[name: ''], state: 'STOPPED']
                        assert_equal Hash[tasks: [expected]],
                                          MultiJson.load(last_response.body, symbolize_keys: true)
                    end
                end
            end
        end

        describe "GET /:namespace/:name" do
            it "returns a code 404 if the name does not exist" do
                get "/tasks/localhost/task/does_not_exist"
                assert_equal 404, last_response.status
            end

            it "returns the task name and model name" do
                with_stub_task_context "task" do |task|
                    get "/tasks/localhost/task"
                    assert_equal 200, last_response.status
                    expected = Hash[name: 'localhost/task', model: Hash[name: ''], state: 'STOPPED']
                    assert_equal Hash[task: expected],
                        MultiJson.load(last_response.body, symbolize_keys: true)
                end
            end
        end

        describe "GET /:namespace/:name/ports" do
            it "returns a code 404 if the task does not exist" do
                get "/tasks/localhost/does_not_exist/ports"
                assert_equal 404, last_response.status
            end

            it "returns the list of all ports" do
                with_stub_task_context "task" do |task|
                    port = task.create_output_port 'port', '/double'
                    get "/tasks/localhost/task/ports"
                    assert_equal 200, last_response.status
                    expected = [Hash[direction: 'output', name: 'port',
                                    type: {name: '/double', class: 'Typelib::NumericType', size: 8, integer: false}]]
                    assert_equal Hash[ports: expected], MultiJson.load(last_response.body, symbolize_keys: true)
                end
            end
        end

        describe "GET /:namespace/:name/ports/:port" do
            it "returns a code 404 if the task does not exist" do
                get "/tasks/localhost/does_not_exist/ports/port_does_not_exist"
                assert_equal 404, last_response.status
            end
            it "returns a code 404 if the task does exist but not the port" do
                with_stub_task_context "task" do |task|
                    get "/tasks/localhost/task/ports/port_does_not_exist"
                    assert_equal 404, last_response.status
                end
            end

            it "returns the port model" do
                with_stub_task_context "task" do |task|
                    port = task.create_output_port 'port', '/double'
                    get "/tasks/localhost/task/ports/port"
                    assert_equal 200, last_response.status
                    expected = Hash[direction: 'output', name: 'port',
                                    type: {name: '/double', class: 'Typelib::NumericType', size: 8, integer: false}]
                    assert_equal Hash[port: expected], MultiJson.load(last_response.body, symbolize_keys: true)
                end
            end

            describe "/read" do
                it "returns a code 408 if no data is received within the expected time" do
                    with_stub_task_context "task" do |task|
                        port = task.create_output_port 'port', '/double'
                        get "/tasks/localhost/task/ports/port/read?timeout=0.05"
                        assert_equal 408, last_response.status
                    end
                end
                it "returns the received sample if called in polling mode" do
                    with_stub_task_context "task" do |task|
                        port = task.create_output_port 'port', '/double'
                        flexmock(Orocos.ruby_task).should_receive(:create_input_port).
                            and_return(flexmock(:raw_read_new => flexmock(:to_simple_value => 10.0),
                                :resolve_connection_from => true, :port= => nil, :policy= => nil))
                        get "/tasks/localhost/task/ports/port/read?timeout=0.05"
                        assert_equal 200, last_response.status
                        assert_equal [Hash[sample: 10]], MultiJson.load(last_response.body, symbolize_keys: true)
                    end
                end

                describe "streaming" do
                    include Minitest::EMSync

                    before do
                        Faye::WebSocket.load_adapter('thin')
                        EM.add_periodic_timer 0.01 do
                            Orocos::Async.event_loop.step
                        end
                        Thin::Logging.level = Logger::WARN
                        @thin = Thin::Server.new('localhost', 9292, app)
                        Orocos::WebApp.install_event_loop
                        @thin.start
                    end

                    after do
                        Orocos::WebApp.remove_event_loop
                        @thin.stop
                    end

                    it "streams the samples if called with a websocket" do
                        with_stub_task_context "task" do |task|
                            port = task.create_output_port 'port', '/double'

                            ws = Faye::WebSocket::Client.new(
                                "ws://localhost:9292/tasks/localhost/task/ports/port/read?count=2")
                            d = EM::DefaultDeferrable.new
                            ws.on(:message) { |msg| d.succeed msg.data }
                            EM.add_periodic_timer(0.01) { port.write 0 }
                            EM.add_timer(2) { d.fail }
                            assert_equal 0, MultiJson.load(sync(d))
                        end
                    end
                end
            end
            
            describe "/write" do
                it "returns a code 500 if the data type is wrong" do
                    with_stub_task_context "task" do |task|
                        port = task.create_input_port 'port', '/double'
                        post "/tasks/localhost/task/ports/port/write" {"test"}
                        assert_equal 500, last_response.status
                    end
                end
                it "writes a value to a port" do
                    with_stub_task_context "task" do |task|
                        port = task.create_intput_port 'port', '/double'
#                        flexmock(Orocos.ruby_task).should_receive(:create_input_port).
#                            and_return(flexmock(:raw_read_new => flexmock(:to_simple_value => 10.0),
#                                :resolve_connection_from => true, :port= => nil, :policy= => nil))
                        post "/tasks/localhost/task/ports/port/write" {"{\"command\":10.0"}
                        assert_equal 201, last_response.status
                        #assert_equal [Hash[sample: 10]], MultiJson.load(last_response.body, symbolize_keys: true)
                    end
                end
            end
        end
    end
end

