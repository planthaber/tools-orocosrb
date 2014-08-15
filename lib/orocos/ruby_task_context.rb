module Orocos
    # Input port created on a RubyTaskContext task instantiated in this Ruby
    # process
    #
    # It is created by RubyTaskContext#create_input_port
    class LocalInputPort < InputPort
        # Reads a sample on this input port
        #
        # For simple types, the returned value is the Ruby representation of the
        # C value.  For instance, C++ strings are represented as String objects,
        # integers as Integer, ...
        #
        # For structures and vectors, the returned value is a representation of
        # that type that Ruby can understand. Field access is transparent:
        #
        #   struct = reader.read
        #   struct.a_field # returns either a simple value or another structure
        #   struct.an_array.each do |element|
        #   end
        def read(sample = nil)
            if value = read_raw(sample)
                Typelib.to_ruby(value)
            end
        end

        # @deprecated use {raw_read} instead
        def read_raw(sample = nil)
            raw_read(sample)
        end

        # Reads a sample on this input port
        #
        # Unlike #read, it will always return a typelib type even for simple types.
        #
        # Raises CORBA::ComError if the communication is broken.
        def raw_read(sample = nil)
            if value = read_helper(sample,true)
                value[0]
            end
        end

        OLD_DATA = 0
        NEW_DATA = 1

        # Reads a new sample on the associated output port.
        #
        # Unlike #read, it will return a non-nil value only if it it different
        # from the last time #read or #read_new has been called
        #
        # For simple types, the returned value is the Ruby representation of the
        # C value.  For instance, C++ strings are represented as String objects,
        # integers as Integer, ...
        #
        # For structures and vectors, the returned value is a representation of
        # that type that Ruby can understand. Field access is transparent:
        #
        #   struct = reader.read
        #   struct.a_field # returns either a simple value or another structure
        #   struct.an_array.each do |element|
        #   end
        #   
        # Raises CORBA::ComError if the communication is broken.
        def read_new(sample = nil)
            if value = read_raw_new(sample)
                Typelib.to_ruby(value)
            end
        end

        # @deprecated use {raw_read_new} instead
        def read_raw_new(sample = nil)
            raw_read_new(sample)
        end

        # Reads a new sample on the associated output port.
        #
        # Unlike #raw_read, it will return a non-nil value only if it it different
        # from the last time #read or #read_new has been called
        #
        # Unlike #read_new, it will always return a typelib type even for simple types.
        #
        # Raises CORBA::ComError if the communication is broken.
        def raw_read_new(sample = nil)
            if value = read_helper(sample, false)
                value[0] if value[1] == NEW_DATA
            end
        end


        # Clears the channel, i.e. "forget" that this port ever got written to
        def clear
            do_clear
        end

        private

        # Helper method for #read, #raw_read, #read_new and #raw_read_new
        # always returns a Typelib Type or nil even for simple types
        def read_helper(sample, copy_old_data) # :nodoc:
            if sample
                if sample.class != type
                    raise ArgumentError, "wrong sample type #{sample.class}, expected #{type}"
                end
                value = sample
            else
                value = type.new
            end

            result = value.allocating_operation do
                do_read(orocos_type_name, value, copy_old_data)
            end
            if result == NEW_DATA || (result == OLD_DATA && copy_old_data)
                if sample
                    sample.invalidate_changes_from_converted_types
                end
                return [value, result]
            end
        end

    end

    # Local input port that is specifically designed to read to another task's output port
    class OutputReader < LocalInputPort
        # The port this object is reading from
        attr_accessor :port

        # The policy of the connection
        attr_accessor :policy

        # Helper method for #read and #read_new
        #
        # This is overloaded in OutputReader to raise CORBA::ComError if the
        # process supporting the remote task is known to be dead
        def read_helper(sample, copy_old_data)
	    if process = port.task.process
		if !process.alive?
		    disconnect_all
		    raise CORBA::ComError, "remote end is dead"
		end
	    end
            super
        end

        # Reads a sample on the associated output port. Returns a value as soon
        # as a sample has ever been written to the port since the data reader
        # has been created
        #
        # @raise [CORBA::ComError] if the remote process is known to be dead.
        # This is only possible if the remote deployment has been started by
        # this Ruby instance
        def read(sample = nil)
            # Only overloaded for documentation reasons
            super
        end

        # Reads a sample on the associated output port, and returns nil if no
        # new data is available
        #
        # @raise [CORBA::ComError] if the remote process is known to be dead.
        # This is only possible if the remote deployment has been started by
        # this Ruby instance
        # @see read
        def read_new(sample = nil)
            # Only overloaded for documentation reasons
            super
        end

        # Disconnects this port from the port it is reading
        def disconnect
            port.disconnect_from(self)
        end
    end

    class LocalOutputPort < OutputPort
        # Write a sample on this output port
        #
        # If the data type is a struct, the sample can be provided either as a
        # Typelib instance object or as a hash.
        #
        # In the first case, one can do:
        #
        #   value = port.new_sample # Get a new sample from the port
        #   value.field = 10
        #   value.other_field = "a_string"
        #   input_writer.write(value)
        #
        # In the second case, 
        #   input_writer.write(:field => 10, :other_field => "a_string")
        def write(data)
            data = Typelib.from_ruby(data, type)
            do_write(orocos_type_name, data)
        end
    end

    # Local output port that is specifically designed to write to another task's input port
    class InputWriter < LocalOutputPort
        # The port this object is reading from
        attr_accessor :port

        # The policy of the connection
        attr_accessor :policy

        # Disconnects this port from the port it is reading
        def disconnect
            disconnect_all
        end

        # Write data on the associated input port
        #
        # @raise [CORBA::ComError] if the remote process is known to be dead or was disconnected.
        # This is only possible if the remote deployment has been started by
        # this Ruby instance
        def write(data)
	    if process = port.task.process
		if !process.alive?
		    disconnect_all
		    raise CORBA::ComError, "remote end is dead"
		end
	    end
            raise CORBA::ComError, "remote end was disconnected" if !super
            # backward compatibility:
            # write was returning true in the case that someone was listening
            # otherwise false
            true
        end
    end

    # A TaskContext that lives inside this Ruby process
    #
    # For now, it has very limited functionality: mainly managing ports
    class RubyTaskContext < TaskContext
        # Internal handler used to represent the local RTT::TaskContext object
        #
        # It is created from Ruby as it handles the RTT::TaskContext pointer
        class LocalTaskContext
            # [Orocos::TaskContext] the remote task
            attr_reader :remote_task
            # [String] the task name
            attr_reader :name

            def initialize(name)
                @name = name
            end
        end

        # Creates a new local task context that fits the given oroGen model
        #
        # @return [RubyTaskContext]
        def self.from_orogen_model(name, orogen_model)
            new(name, :model => orogen_model)
        end

        # Creates a new ruby task context with the given name
        #
        # @param [String] name the task name
        # @return [RubyTaskContext]
        def self.new(name, options = Hash.new, &block)
            options, _ = Kernel.filter_options options, :model

            if block && !options[:model]
                model = Orocos::Spec::TaskContext.new(Orocos.master_project, name)
                model.instance_eval(&block)
                options[:model] = model
            end

            local_task = LocalTaskContext.new(name)
            if options[:model] && options[:model].name
                local_task.model_name = options[:model].name
            end

            remote_task = super(local_task.ior, options)
            local_task.instance_variable_set :@remote_task, remote_task
            remote_task.instance_variable_set :@local_task, local_task

            if options[:model]
                remote_task.setup_from_orogen_model(options[:model])
            end
            remote_task
        end

        def initialize(ior, options = Hash.new)
            @local_ports = Hash.new
            @local_properties = Hash.new
            options, other_options = Kernel.filter_options options, :name => name
            super(ior, other_options.merge(options))
        end

        # Create a new input port on this task context
        #
        # @param [String] name the port name. It must be unique among all port
        #   types
        # @param [String] orocos_type_name the name of the port's type, as
        #   recognized by Orocos. In most cases, it is the same than the
        #   typelib type name
        # @option options [Boolean] :permanent if true (the default), the port
        #   will be stored permanently on the task. Otherwise, it will be
        #   removed as soon as the port object gets garbage collected by Ruby
        # @option options [Class] :class the class that should be used to
        #   represent the port on the Ruby side. Do not change unless you know
        #   what you are doing
        def create_input_port(name, orocos_type_name, options = Hash.new)
            options, other_options = Kernel.filter_options options,
                :class => LocalInputPort,
                :permanent => true
            port = create_port(false, options[:class], name, orocos_type_name,
                               other_options.merge(:permanent => options[:permanent]))
            if options[:permanent]
                port.model = model.input_port(name, port.orocos_type_name)
            end
            port
        end

        # Create a new output port on this task context
        #
        # @param [String] name the port name. It must be unique among all port
        #   types
        # @param [String] orocos_type_name the name of the port's type, as
        #   recognized by Orocos. In most cases, it is the same than the
        #   typelib type name
        # @option options [Boolean] :permanent if true (the default), the port
        #   will be stored permanently on the task. Otherwise, it will be
        #   removed as soon as the port object gets garbage collected by Ruby
        # @option options [Class] :class the class that should be used to
        #   represent the port on the Ruby side. Do not change unless you know
        #   what you are doing
        def create_output_port(name, orocos_type_name, options = Hash.new)
            options, other_options = Kernel.filter_options options,
                :class => LocalOutputPort,
                :permanent => true
            port = create_port(true, options[:class], name, orocos_type_name,
                               other_options.merge(:permanent => options[:permanent]))
            if options[:permanent]
                port.model = model.output_port(name, port.orocos_type_name)
            end
            port
        end

        # Remove the given port from this task's interface
        #
        # @param [LocalInputPort,LocalOutputPort] port the port to be removed
        # @return [void]
        def remove_port(port)
            @local_ports.delete(port.name)
            port.disconnect_all # don't wait for the port to be garbage collected by Ruby
            @local_task.do_remove_port(port.name)
        end

        # Deregisters this task context.
        #
        # This is done automatically when the object is garbage collected.
        # However, it is sometimes better to do this explicitely, for instance
        # to avoid the name clash warning.
        def dispose
            @local_task.dispose
        end

        # Creates a new property on this task context
        #
        # @param [String] name the property name
        # @param [Model<Typelib::Type>,String] type the type or type name
        # @option options [Boolean] :init (true) if true, the new property will
        #   be initialized with a fresh sample. Otherwise, it is left alone. This
        #   is mostly to avoid crashes / misbehaviours in case smart pointers are
        #   used
        # @return [Property] the property object
        def create_property(name, type, options = Hash.new)
            options = Kernel.validate_options options, :init => true

            orocos_type_name = find_orocos_type_name_by_type(type)
            Orocos.load_typekit_for orocos_type_name
            local_property = @local_task.do_create_property(Property, name, orocos_type_name)
            @local_properties[local_property.name] = local_property
            @properties[local_property.name] = local_property
            if options[:init]
                local_property.write(local_property.new_sample)
            end
            local_property
        end

        # Sets up the interface of this task context so that it matches the
        # given oroGen model
        #
        # @param [Orocos::Spec::TaskContext] orogen_model the oroGen model
        # @return [void]
        def setup_from_orogen_model(orogen_model)
            new_properties, new_outputs, new_inputs = [], [], []
            remove_outputs, remove_inputs = [], []

            orogen_model.each_property do |p|
                if has_property?(p.name)
                    if property(p.name).orocos_type_name != p.orocos_type_name
                        raise IncompatibleInterface, "cannot adapt the interface of #{self} to match the model in #{orogen_model}: #{self} already has a property called #{p.name}, but with a different type"
                    end
                else new_properties << p
                end
            end
            orogen_model.each_input_port do |p|
                if has_port?(p.name)
                    if port(p.name).orocos_type_name != p.orocos_type_name
                        remove_inputs << p
                        new_inputs << p
                    end
                else new_inputs << p
                end
            end
            orogen_model.each_output_port do |p|
                if has_port?(p.name)
                    if port(p.name).orocos_type_name != p.orocos_type_name
                        remove_outputs << p
                        new_outputs << p
                    end
                else new_outputs << p
                end
            end

            remove_inputs.each { |p| remove_input_port p }
            remove_outputs.each { |p| remove_output_port p }
            new_properties.each do |p|
                create_property(p.name, p.orocos_type_name)
            end
            new_inputs.each do |p|
                create_input_port(p.name, p.orocos_type_name)
            end
            new_outputs.each do |p|
                create_output_port(p.name, p.orocos_type_name)
            end
            @model = orogen_model
            nil
        end

        def find_orocos_type_name_by_type(type)
            if type.respond_to?(:name)
                type = type.name
            end
            type = Orocos.master_project.find_type(type)
            type = Orocos.master_project.find_opaque_for_intermediate(type) || type
            type = Orocos.master_project.find_interface_type(type)
            if Orocos.registered_type?(type.name)
                type.name
            else Typelib::Registry.rtt_typename(type)
            end
        end

        private

        # Helper method for create_input_port and create_output_port
        def create_port(is_output, klass, name, type, options)
            # Load the typekit, but no need to check on it being exported since
            # #find_orocos_type_name_by_type will do it for us
            Orocos.load_typekit_for(type, false)
            orocos_type_name = find_orocos_type_name_by_type(type)
            Orocos.load_typekit_for(orocos_type_name, true)

            options = Kernel.validate_options options, :permanent => true
            local_port = @local_task.do_create_port(is_output, klass, name, orocos_type_name)
            if options[:permanent]
                @local_ports[local_port.name] = local_port
                @ports[local_port.name] = local_port
            end
            local_port
        end
    end
end
