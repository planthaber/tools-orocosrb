module Orocos
    module RobyPlugin
        # Represents the actual connection graph between task context proxies.
        # Its vertices are instances of Orocos::TaskContext, and edges are
        # mappings from [source_port_name, sink_port_name] pairs to the
        # connection policy between these ports.
        #
        # Orocos::RobyPlugin::ActualDataFlow is the actual global graph instance
        # in which the overall system connections are maintained in practice
        class ConnectionGraph < BGL::Graph
            def add_connections(source_task, sink_task, mappings) # :nodoc:
                if mappings.empty?
                    raise ArgumentError, "the connection set is empty"
                end
                if linked?(source_task, sink_task)
                    current_mappings = source_task[sink_task, self]
                    new_mappings = current_mappings.merge(mappings) do |(from, to), old_options, new_options|
                        if old_options.empty? then new_options
                        elsif new_options.empty? then old_options
                        elsif old_options != new_options
                            raise Roby::ModelViolation, "cannot override connection setup with #connect_to (#{old_options} != #{new_options})"
                        end
                        old_options
                    end
                    source_task[sink_task, self] = new_mappings
                else
                    link(source_task, sink_task, mappings)
                end
            end

            def remove_connections(source_task, sink_task, mappings) # :nodoc:
                current_mappings = source_task[sink_task, self]
                mappings.each do |source_port, sink_port|
                    current_mappings.delete([source_port, sink_port])
                end
                if current_mappings.empty?
                    unlink(source_task, sink_task)
                end
            end

            def has_out_connections?(task, port)
                task.each_child_vertex(self) do |child_task|
                    if task[child_task, self].any? { |source_port, _| source_port == port }
                        return true
                    end
                end
                false
            end

            def has_in_connections?(task, port)
                task.each_parent_vertex(self) do |parent_task|
                    if parent_task[task, self].any? { |_, target_port| target_port == port }
                        return true
                    end
                end
                false
            end

            def connected?(source_task, source_port, sink_task, sink_port)
                if !linked?(source_task, sink_task)
                    return false
                end
                source_task[sink_task, self].has_key?([source_port, sink_port])
            end
        end

        ActualDataFlow   = ConnectionGraph.new
        Orocos::TaskContext.include BGL::Vertex

        def self.update_connection_policy(old, new)
            old = old.dup
            new = new.dup
            if old.empty?
                return new
            elsif new.empty?
                return old
            end

            old = Port.validate_policy(old)
            new = Port.validate_policy(new)
            if old[:type] != new[:type]
                raise ArgumentError, "connection types mismatch: #{old[:type]} != #{new[:type]}"
            end
            type = old[:type]

            if type == :buffer
                if new.size != old.size
                    raise ArgumentError, "connection policy mismatch: #{old} != #{new}"
                end

                old.merge(new) do |key, old_value, new_value|
                    if key == :size
                        [old_value, new_value].max
                    elsif old_value != new_value
                        raise ArgumentError, "connection policy mismatch for #{key}: #{old_value} != #{new_value}"
                    else
                        old_value
                    end
                end
            elsif old == new.slice(*old.keys)
                new
            end
        end

        Flows = Roby::RelationSpace(Component)
        Flows.relation :DataFlow, :child_name => :sink, :parent_name => :source, :dag => false, :weak => true do
            # Makes sure that +self+ has an output port called +name+. It will
            # instanciate a dynamic port if needed.
            #
            # Raises ArgumentError if no such port can ever exist on +self+
            def ensure_has_output_port(name)
                if !model.output_port(name)
                    if model.dynamic_output_port?(name)
                        instanciate_dynamic_output(name)
                    else
                        raise ArgumentError, "#{self} has no output port called #{name}"
                    end
                end
            end

            # Makes sure that +self+ has an input port called +name+. It will
            # instanciate a dynamic port if needed.
            #
            # Raises ArgumentError if no such port can ever exist on +self+
            def ensure_has_input_port(name)
                if !model.input_port(name)
                    if model.dynamic_input_port?(name)
                        instanciate_dynamic_input(name)
                    else
                        raise ArgumentError, "#{self} has no input port called #{name}"
                    end
                end
            end

            def clear_relations
                Flows::DataFlow.remove(self)
                super
            end

            # Forward an input port of a composition to one of its children, or
            # an output port of a composition's child to its parent composition.
            #
            # +mappings+ is a hash of the form
            #
            #   source_port_name => sink_port_name
            #
            # If the +self+ composition is the parent of +target_task+, then
            # source_port_name must be an input port of +self+ and
            # sink_port_name an input port of +target_task+.
            #
            # If +self+ is a child of the +target_task+ composition, then
            # source_port_name must be an output port of +self+ and
            # sink_port_name an output port of +target_task+.
            #
            # Raises ArgumentError if one of the specified ports do not exist,
            # or if +target_task+ and +self+ are not related in the Dependency
            # relation.
            def forward_ports(target_task, mappings)
                if self.child_object?(target_task, Roby::TaskStructure::Dependency)
                    if !fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        ensure_has_input_port(from)
                        target_task.ensure_has_input_port(to)
                    end

                elsif target_task.child_object?(self, Roby::TaskStructure::Dependency)
                    if !target_task.fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        ensure_has_output_port(from)
                        target_task.ensure_has_output_port(to)
                    end
                else
                    raise ArgumentError, "#{target_task} and #{self} are not related in the Dependency relation"
                end

                add_sink(target_task, mappings)
            end

            # Connect a set of ports between +self+ and +target_task+.
            #
            # +mappings+ describes the connections. It is a hash of the form
            #   
            #   [source_port_name, sink_port_name] => connection_policy
            #
            # where source_port_name is a port of +self+ and sink_port_name a
            # port of +target_task+
            #
            # Raises ArgumentError if one of the ports do not exist.
            def connect_ports(target_task, mappings)
                mappings.each do |(out_port, in_port), options|
                    ensure_has_output_port(out_port)
                    target_task.ensure_has_input_port(in_port)
                end

                add_sink(target_task, mappings)
            end

            # call-seq:
            #   sink_task.each_input_connection { |source_task, source_port_name, sink_port_name, policy| ...}
            #
            # Yield or enumerates the connections that exist towards the input
            # ports of +sink_task+. It includes connections to composition ports
            # (i.e. exported ports).
            def each_input_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_input_connection)
                end

                each_source do |source_task|
                    source_task[self, Flows::DataFlow].each do |(source_port, sink_port), policy|
                        if required_port 
                            if sink_port == required_port
                                yield(source_task, source_port, sink_port, policy)
                            end
                        else
                            yield(source_task, source_port, sink_port, policy)
                        end
                    end
                end
            end

            # call-seq:
            #   sink_task.each_input_connection { |source_task, source_port_name, sink_port_name, policy| ...}
            #
            # Yield or enumerates the connections that exist towards the input
            # ports of +sink_task+. It does not include connections to
            # composition ports (i.e. exported ports): these connections are
            # followed until a concrete port (a port on an actual Orocos
            # task context) is found.
            def each_concrete_input_connection(required_port = nil, &block)
                if !block_given?
                    return enum_for(:each_concrete_input_connection, required_port)
                end

                each_input_connection(required_port) do |source_task, source_port, sink_port, policy|
                    # Follow the forwardings while +sink_task+ is a composition
                    if source_task.kind_of?(Composition)
                        source_task.each_concrete_input_connection(source_port) do |source_task, source_port, _, connection_policy|
                            begin
                                this_policy = RobyPlugin.update_connection_policy(policy, connection_policy)
                            rescue ArgumentError => e
                                raise SpecError, "incompatible policies in input chain for #{self}:#{sink_port}: #{e.message}"
                            end

                            yield(source_task, source_port, sink_port, policy)
                        end
                    else
                        yield(source_task, source_port, sink_port, policy)
                    end
                end
                self
            end

            def each_concrete_output_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_concrete_output_connection, required_port)
                end

                each_output_connection(required_port) do |source_port, sink_port, sink_task, policy|
                    # Follow the forwardings while +sink_task+ is a composition
                    if sink_task.kind_of?(Composition)
                        sink_task.each_concrete_output_connection(sink_port) do |_, sink_port, sink_task, connection_policy|
                            begin
                                this_policy = RobyPlugin.update_connection_policy(policy, connection_policy)
                            rescue ArgumentError => e
                                raise SpecError, "incompatible policies in output chain for #{self}:#{source_port}: #{e.message}"
                            end
                            yield(source_port, sink_port, sink_task, this_policy)
                        end
                    else
                        yield(source_port, sink_port, sink_task, policy)
                    end
                end
                self
            end

            # call-seq:
            #   source_task.each_output_connection { |source_port_name, sink_port_name, sink_port, policy| ...}
            #
            # Yield or enumerates the connections that exist getting out
            # of the ports of +source_task+. It does not include connections to
            # composition ports (i.e. exported ports): these connections are
            # followed until a concrete port (a port on an actual Orocos
            # task context) is found.
            #
            # If +required_port+ is given, it must be a port name, and only the
            # connections going out of this port will be yield.
            def each_output_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_output_connection, required_port)
                end

                each_sink do |sink_task, connections|
                    connections.each do |(source_port, sink_port), policy|
                        if required_port
                            if required_port == source_port
                                yield(source_port, sink_port, sink_task, policy)
                            end
                        else
                            yield(source_port, sink_port, sink_task, policy)
                        end
                    end
                end
                self
            end

        end

        module Flows
            class << DataFlow
                # The set of connection changes that have been applied to the
                # DataFlow relation graph, but not yet applied on the actual
                # components (i.e. not yet present in the ActualDataFlow graph).
                attr_accessor :pending_changes
            end

            # Returns the set of tasks whose data flow has been changed that has
            # not yet been applied.
            def DataFlow.modified_tasks
                @modified_tasks ||= ValueSet.new
            end

            # Called by the relation graph management to update the DataFlow
            # edge information when connections are added or removed.
            def DataFlow.merge_info(source, sink, current_mappings, additional_mappings)
                current_mappings.merge(additional_mappings) do |(from, to), old_options, new_options|
                    RobyPlugin.update_connection_policy(old_options, new_options)
                end
            end
        end

        RequiredDataFlow = ConnectionGraph.new
    end
end
