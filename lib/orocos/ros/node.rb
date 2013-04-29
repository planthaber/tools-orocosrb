module Orocos
    module ROS
        # A TaskContext-compatible interface of a ROS node
        #
        # The following caveats apply:
        #
        # * ROS nodes do not have an internal lifecycle state machine. In
        #   practice, it means that #configure has no effect, #start will start
        #   the node's process and #stop will kill it (if we have access to it).
        #   If the ROS process is not managed by orocos.rb, they will throw
        # * ROS nodes do not allow modifying subscriptions at runtime, so the
        #   port connection / disconnection methods can only be used while the
        #   node is not running
        class Node
            # [NameService] access to the state of the ROS graph
            attr_reader :name_service
            # [ROSSlave] access to the node XMLRPC API
            attr_reader :server
            # [String] the node name
            attr_reader :name
            # [Hash<String,Topic>] a cache of the topics that are known to be
            # associated with this node. It should never be used directly, as it
            # may contain stale entries
            attr_reader :topics
            # The underlying process object that represents this node
            # It is non-nil only if this node has been started by orocos.rb
            # @return [nil]
            attr_reader :process
            # @return [Orocos::Spec::TaskContext] the oroGen model that describes this node
            attr_reader :model

            def initialize(name_service, server, name, model = nil)
                @name_service = name_service
                @server = server
                @name = name
                @input_topics = Hash.new
                @output_topics = Hash.new
                @model = model
            end

            def ==(other)
                other.class == self.class &&
                    other.name_service == self.name_service &&
                    other.name == self.name
            end

            # True if this task's model is a subclass of the provided class name
            #
            # This is available only if the deployment in which this task context
            # runs has been generated by orogen.
            def implements?(class_name)
                model && model.implements?(class_name)
            end

            def state
                :RUNNING
            end

            def reachable?
                name_service.has_node?(name)
                true
            rescue ComError
                false
            end

            def doc?; false end
            attr_reader :doc

            def each_property; end

            def port_names
                each_port.map(&:name)
            end

            def property_names; [] end
            def attribute_names; [] end

            def has_port?(name)
                !!(find_output_port(name) || find_input_port(name))
            end

            def port(name, verify = true)
                p = (find_output_port(name, verify) || find_input_port(name, verify))
                if !p
                    raise Orocos::NotFound, "cannot find topic #{name} attached to node #{name}"
                end
                p
            end

            def input_port(name, verify = true)
                p = find_input_port(name, verify)
                if !p
                    raise Orocos::NotFound, "cannot find topic #{name} as a subscription of node #{self.name}"
                end
                p
            end

            def output_port(name, verify = true)
                p = find_output_port(name, verify)
                if !p
                    raise Orocos::NotFound, "cannot find topic #{name} as a publication of node #{self.name}"
                end
                p
            end
            
            # Finds the name of a topic this node is publishing
            #
            # @return [ROS::Topic,nil] the topic if found, nil otherwise
            def find_output_port(name, verify = true, wait_if_unavailable = true)
                each_output_port(verify) do |p|
                    if p.name == name || p.topic_name == name
                        return p
                    end
                end
                if verify && wait_if_unavailable
                    name_service.wait_for_update
                    find_output_port(name, true, false)
                end
            end
            
            # Finds the name of a topic this node is subscribed to
            #
            # @return [ROS::Topic,nil] the topic if found, nil otherwise
            def find_input_port(name, verify = true, wait_if_unavailable = true)
                each_input_port(verify) do |p|
                    if p.name == name || p.topic_name == name
                        return p
                    end
                end
                if verify && wait_if_unavailable
                    name_service.wait_for_update
                    find_input_port(name, true, false)
                end
            end

            def each_port(verify = true)
                return enum_for(:each_port, verify) if !block_given?
                each_output_port(verify) { |p| yield(p) }
                each_input_port(verify) { |p| yield(p) }
            end

            # Enumerates each "output topics" of this node
            def each_output_port(verify = true)
                return enum_for(:each_output_port, verify) if !block_given?

                if !verify
                    return @output_topics.values.each(&proc)
                end
                
                name_service.output_topics_for(name).each do |topic_name, topic_type|
                    topic_type = name_service.topic_message_type(topic_name)
                    if ROS.compatible_message_type?(topic_type)
                        topic = (@output_topics[topic_name] ||= OutputTopic.new(self, topic_name, topic_type))
                        yield(topic)
                    end
                end
            end

            # Enumerates each "input topics" of this node
            def each_input_port(verify = true)
                return enum_for(:each_input_port, verify) if !block_given?

                if !verify
                    return @input_topics.values.each(&proc)
                end

                name_service.input_topics_for(name).each do |topic_name|
                    topic_type = name_service.topic_message_type(topic_name)
                    if ROS.compatible_message_type?(topic_type)
                        topic = (@input_topics[topic_name] ||= InputTopic.new(self, topic_name, topic_type))
                        yield(topic)
                    end
                end
            end

            def pretty_print(pp)
                pp.text "ROS Node #{name}"
                pp.breakable

                inputs  = each_input_port.to_a
                outputs = each_output_port.to_a
                ports = enum_for(:each_port).to_a
                if ports.empty?
                    pp.text "No ports"
                    pp.breakable
                else
                    pp.text "Ports:"
                    pp.breakable
                    pp.nest(2) do
                        pp.text "  "
                        each_port do |port|
                            port.pretty_print(pp)
                            pp.breakable
                        end
                    end
                    pp.breakable
                end
            end

            # @return [Orocos::Async::ROS::Node] an object that gives
            #   asynchronous access to this particular ROS node
            def to_async(options = Hash.new)
                Async::ROS::Node.new(name_service, server, name, options)
            end

            def to_proxy(options = Hash.new)
                options[:use] ||= to_async
                # use name service to check if there is already 
                # a proxy for the task
                Orocos::Async.proxy(name,options.merge(:name_service => name_service))
            end

            # Tests if this node is still available
            #
            # @raise [Orocos::ComError] if the node is not available anymore
            def ping
                if !name_service.has_node?(name)
                    raise Orocos::ComError, "ROS node #{name} is not available on the ROS graph anymore"
                end
            end

            # Returns the set of new states
            def states; [:RUNNING] end

            def peek_state; :RUNNING end
            def state; :RUNNING end
            def state_changed?; false end
        end
    end
end


