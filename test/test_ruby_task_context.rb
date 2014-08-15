$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
require 'minitest/spec'
require 'orocos'
require 'orocos/test'

MiniTest::Unit.autorun

TEST_DIR = File.expand_path(File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

describe Orocos::RubyTaskContext do
    include Orocos
    include Orocos::Spec

    it "should be registered on the name server" do
        task = new_ruby_task_context("task")
        assert Orocos.name_service.get("task")
    end

    it "should refer to a LocalTaskContext object that refers to it back" do
        task = new_ruby_task_context("task")
        assert_same task, task.instance_variable_get(:@local_task).remote_task
    end

    it "can create output ports" do
        task = new_ruby_task_context("producer")
        port = task.create_output_port("p", "/int32_t")
        assert_kind_of Orocos::OutputPort, port
        assert_equal task, port.task
        assert_equal "p", port.name

        assert task.has_port?("p")
        assert_kind_of Orocos::OutputPort, task.port("p")
        assert_equal "/int32_t", task.port("p").orocos_type_name
    end

    it "creates a model for a created output port" do
        task = new_ruby_task_context("producer")
        port = task.create_output_port("p", "/int32_t")
        assert_kind_of Orocos::Spec::OutputPort, port.model
        assert_equal 'p', port.model.name
        assert_equal '/int32_t', port.model.type.name
    end

    it "can create input ports" do
        task = new_ruby_task_context("producer")
        port = task.create_input_port("p", "/int32_t")

        assert_kind_of Orocos::InputPort, port
        assert task.has_port?("p")
        assert_kind_of Orocos::InputPort, task.port("p")
        assert_equal "/int32_t", task.port("p").orocos_type_name

    it "creates a model for a created input port" do
        task = new_ruby_task_context("producer")
        port = task.create_input_port("p", "/int32_t")
        assert_kind_of Orocos::Spec::InputPort, port.model
        assert_equal 'p', port.model.name
        assert_equal '/int32_t', port.model.type.name
    end

    it "can write and read on ports" do
        producer = new_ruby_task_context("producer")
        out_p = producer.create_output_port("p", "int")
        consumer = new_ruby_task_context("consumer")
        in_p = consumer.create_input_port("p", "int")

        out_p.connect_to in_p
        out_p.write 10
        assert_equal 10, in_p.read
    end

    describe "#create_property" do
        it "can create a property" do
            task = new_ruby_task_context("task")
            property = task.create_property('prop', 'int')
            assert_kind_of Orocos::Property, property
            assert_same property, task.property('prop')
            assert task.has_property?('prop')
        end
        it "initializes the property with a sample" do
            Orocos.load_typekit 'echo'
            opaque_t       = Orocos.registry.get '/OpaquePoint'
            intermediate_t = Orocos.registry.get '/echo/Point'
            initial_sample = intermediate_t.new
            initial_sample.x = 1
            initial_sample.y = 0
            flexmock(intermediate_t).should_receive(:new).and_return(initial_sample)
            task = new_ruby_task_context('task')
            task.create_property 'p', '/OpaquePoint'
            assert_equal initial_sample, task.p
        end
    end

    it "can read and write properties" do
        task = new_ruby_task_context("task")
        property = task.create_property('prop', 'int')
        property.write(10)
        assert_equal 10, property.read
        property.write(20)
        assert_equal 20, property.read
    end

    it "allows to get access to the model name if one is given" do
        model = Orocos::Spec::TaskContext.new(nil, 'myModel')
        task = new_ruby_task_context('task', :model => model)
        assert_equal "myModel", task.getModelName
    end

    it "makes #model returns the oroGen model if given" do
        model = Orocos::Spec::TaskContext.new
        task = new_ruby_task_context('task', :model => model)
        assert_same model, task.model
    end

    it "allows to handle the normal state changes" do
        task = new_ruby_task_context('task')
        assert_equal :STOPPED, task.rtt_state
        task.start
        assert_equal :RUNNING, task.rtt_state
        task.stop
        assert_equal :STOPPED, task.rtt_state
    end

    describe "#find_orocos_type_name_by_type" do
        attr_reader :ruby_task
        before do
            Orocos.load_typekit 'echo'
            @ruby_task = new_ruby_task_context('task')
        end
        it "can be given an opaque type directly" do
            assert_equal '/OpaquePoint', ruby_task.find_orocos_type_name_by_type('/OpaquePoint')
            assert_equal '/OpaquePoint', ruby_task.find_orocos_type_name_by_type(Orocos.registry.get('/OpaquePoint'))
        end
        it "can be given an opaque-containing type directly" do
            assert_equal '/OpaqueContainingType', ruby_task.find_orocos_type_name_by_type('/OpaqueContainingType')
            assert_equal '/OpaqueContainingType', ruby_task.find_orocos_type_name_by_type(Orocos.registry.get('/OpaqueContainingType'))
        end
        it "converts a non-exported intermediate type to the corresponding opaque" do
            assert_equal '/OpaquePoint', ruby_task.find_orocos_type_name_by_type('/echo/Point')
            assert_equal '/OpaquePoint', ruby_task.find_orocos_type_name_by_type(Orocos.registry.get('/echo/Point'))
        end
        it "converts a non-exported m-type to the corresponding opaque-containing type" do
            assert_equal '/OpaqueContainingType', ruby_task.find_orocos_type_name_by_type('/OpaqueContainingType_m')
            assert_equal '/OpaqueContainingType', ruby_task.find_orocos_type_name_by_type(Orocos.registry.get('/OpaqueContainingType_m'))
        end
        it "successfully converts a basic type to the corresponding orocos type name" do
            typename = Orocos.registry.get('int').name
            refute_equal 'int', typename
            assert_equal '/int32_t', ruby_task.find_orocos_type_name_by_type(typename)
            assert_equal '/int32_t', ruby_task.find_orocos_type_name_by_type(Orocos.registry.get('int'))
        end
        it "raises if given a non-exported type" do
            assert_raises(Orocos::Generation::ConfigError) { ruby_task.find_orocos_type_name_by_type('/NonExportedType') }
            assert_raises(Orocos::Generation::ConfigError) { ruby_task.find_orocos_type_name_by_type(Orocos.registry.get('/NonExportedType')) }
        end
    end
end

