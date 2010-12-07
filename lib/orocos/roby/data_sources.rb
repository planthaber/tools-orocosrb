module Orocos
    module RobyPlugin
        # Namespace in which data services are stored.
        #
        # When a service is declared with
        #
        #   data_service 'a_name_in_snake_case'
        #
        # The plugin creates a
        # Orocos::RobyPlugin::DataServices::ANameInSnakeCase instance of the
        # DataServiceModel class. This instance then gets included in every task
        # context model and device model that provides the service.
        #
        # A Orocos::Generation::TaskContext instance is used to represent the
        # service interface. This instance is available through the 'interface'
        # attribute of the DataServiceModel instance.
        module DataServices
        end

        # Namespace in which device models are stored.
        #
        # When a device is declared with
        #
        #   device 'a_name_in_snake_case'
        #
        # The plugin creates a
        # Orocos::RobyPlugin::Devices::ANameInSnakeCase instance of the
        # DataServiceModel class. This instance then gets included in every task
        # context model that provides the service.
        #
        # A Orocos::Generation::TaskContext instance is used to represent the
        # service interface. This instance is available through the 'interface'
        # attribute of the DataServiceModel instance.
        module Devices
        end

        DataSources = Devices
        DServ = DataServices
        DSrc  = DataSources

        # Base type for data service models (DataService, DataSource,
        # DataBus). Methods defined in this class are available on said
        # models (for instance DataSource.new_submodel)
        class DataServiceModel < Roby::TaskModelTag
            # The name of the model
            attr_accessor :name
            # The parent model, if any
            attribute(:parent_models) { ValueSet.new }
            # The configuration type for instances of this service model
            attr_writer :config_type
            # Port mappings from this service's parent models to the service
            # itself
            #
            # Whenever a data service provides another one, it is possible to
            # specify that some ports of the provided service are mapped onto th
            # ports of the new service. This hash keeps track of these port
            # mappings.
            #
            # The mapping is of the form
            #   
            #   [service_model, port] => target_port
            attribute(:port_mappings) { Hash.new }

            # Return the config type for the instances of this service, if any
            def config_type
                ancestors = self.ancestors
                for klass in ancestors
                    if type = klass.instance_variable_get(:@config_type)
                        return type
                    end
                end
                type
            end

            def short_name
                name.gsub('Orocos::RobyPlugin::', '')
            end

            # Creates a new DataServiceModel that is a submodel of +self+
            def new_submodel(name, options = Hash.new)
                options = Kernel.validate_options options,
                    :type => self.class, :interface => nil, :system_model => nil

                model = options[:type].new
                model.name = name.dup
                model.system_model = options[:system_model]

                child_spec = model.create_orogen_interface
                if options[:interface]
                    RobyPlugin.merge_orogen_interfaces(child_spec, [Roby.app.get_orocos_task_model(options[:interface]).orogen_spec])
                end
                model.instance_variable_set :@orogen_spec, child_spec
                model.provides self
                model
            end

            class BlockInstanciator < BasicObject
                def initialize(service)
                    @service = service
                    @interface = service.interface
                end

                def method_missing(m, *args, &block)
                    if @interface.respond_to?(m)
                        @interface.send(m, *args, &block)
                    else @service.send(m, *args, &block)
                    end
                end
            end

            def apply_block(&block)
                BlockInstanciator.new(self).instance_eval(&block)
            end

            def port_mappings_for(service_type)
                result = port_mappings[service_type]
                if !result
                    raise ArgumentError, "#{service_type.short_name} is not provided by #{short_name}"
                end
                result
            end

            def provides(service_model, new_port_mappings = Hash.new)
                include service_model
                parent_models << service_model

                service_model.port_mappings.each do |original_service, mappings|
                    updated_mappings = Hash.new
                    mappings.each do |from, to|
                        updated_mappings[from] = new_port_mappings[to] || to
                    end
                    port_mappings[original_service] =
                        SystemModel.merge_port_mappings(port_mappings[original_service] || Hash.new, updated_mappings)
                end
                port_mappings[service_model] =
                    SystemModel.merge_port_mappings(port_mappings[service_model] || Hash.new, new_port_mappings)

                if service_model.interface
                    RobyPlugin.merge_orogen_interfaces(interface, [service_model.interface], new_port_mappings)
                end
            end

            def create_orogen_interface
                RobyPlugin.create_orogen_interface(name)
            end

            attr_reader :orogen_spec

            def interface
                if block_given?
                    raise ArgumentError, "interface(&block) is not available anymore"
                end
                orogen_spec
            end

            def each_port_name_candidate(port_name, main_service = false, source_name = nil)
                if !block_given?
                    return enum_for(:each_port_name_candidate, port_name, main_service, source_name)
                end

                if source_name
                    if main_service
                        yield(port_name)
                    end
                    yield("#{source_name}_#{port_name}".camelcase(:inter))
                    yield("#{port_name}_#{source_name}".camelcase(:inter))
                else
                    yield(port_name)
                end
                self
            end

            # Try to guess the name under which a data service whose model is
            # +self+ could be declared on +model+, by following port name rules.
            #
            # Returns nil if no match has been found
            def guess_source_name(model)
                port_list = lambda do |m|
                    result = Hash.new { |h, k| h[k] = Array.new }
                    m.each_output_port do |source_port|
                        result[ [true, source_port.type_name] ] << source_port.name
                    end
                    m.each_input_port do |source_port|
                        result[ [false, source_port.type_name] ] << source_port.name
                    end
                    result
                end

                required_ports  = port_list[self]
                available_ports = port_list[model]

                candidates = nil
                required_ports.each do |spec, names|
                    return if !available_ports.has_key?(spec)

                    available_names = available_ports[spec]
                    names.each do |required_name|
                        matches = available_names.map do |n|
                            if n == required_name then ''
                            elsif n =~ /^(.+)#{Regexp.quote(required_name).capitalize}$/
                                $1
                            elsif n =~ /^#{Regexp.quote(required_name)}(.+)$/
                                name = $1
                                name[0, 1] = name[0, 1].downcase
                                name
                            end
                        end.compact

                        if !candidates
                            candidates = matches
                        else
                            candidates.delete_if { |candidate_name| !matches.include?(candidate_name) }
                        end
                        return if candidates.empty?
                    end
                end

                candidates
            end

            # Returns true if a port mapping is needed between the two given
            # data services. Note that this relation is symmetric.
            #
            # It is assumed that the name0 service in model0 and the name1
            # service
            # in model1 are of compatible types (same types or derived types)
            def self.needs_port_mapping?(from, to)
                from.port_mappings != to.port_mappings
            end

            # Returns the most generic task model that implements +self+. If
            # more than one task model is found, raises Ambiguous
            def task_model
                if @task_model
                    return @task_model
                end

                @task_model = Class.new(DataServiceProxy)
                @task_model.abstract
                @task_model.fullfilled_model = [Roby::Task, [self], {}]
                @task_model.instance_variable_set(:@orogen_spec, orogen_spec)
                @task_model.name = name
                @task_model.data_service self
                @task_model
            end

            include ComponentModel

            def instanciate(*args, &block)
                task_model.instanciate(*args, &block)
            end

            def to_s # :nodoc:
                "#<DataService: #{name}>"
            end
        end

        DataService  = DataServiceModel.new
        DataSource   = DataServiceModel.new
        ComBusDriver = DataServiceModel.new

        module DataService
            @name = "Orocos::RobyPlugin::DataService"

            def to_short_s
                to_s.gsub /Orocos::RobyPlugin::/, ''
            end

            module ClassExtension
                def find_data_services(&block)
                    each_data_service.find_all(&block)
                end

                def each_data_source(&block)
                    each_data_service.find_all { |_, srv| srv.model < DataSource }.
                        each(&block)
                end

                # Generic data service selection method, based on a service type
                # and an optional service name. It implements the following
                # algorithm:
                #  
                #  * only services that match +target_model+ are considered
                #  * if there is only one service of that type and no pattern is
                #    given, that service is returned
                #  * if there is a pattern given, it must be either the service
                #    full name or its subname (for slaves)
                #  * if an ambiguity is found between root and slave data
                #    services, and there is only one root data service matching,
                #    that data service is returned.
                def find_matching_service(target_model, pattern = nil)
                    # Find services in +child_model+ that match the type
                    # specification
                    matching_services = find_all_services_from_type(target_model)

                    if pattern # match by name too
                        # Find the selected service. There can be shortcuts, so
                        # for instance bla.left would be able to select both the
                        # 'left' main service or the 'bla.blo.left' slave
                        # service.
                        rx = /(^|\.)#{pattern}$/
                        matching_services.delete_if { |service| service.full_name !~ rx }
                    end

                    if matching_services.size > 1
                        main_matching_services = matching_services.
                            find_all { |service| service.master? }

                        if main_matching_services.size != 1
                            raise Ambiguous, "there is more than one service of type #{target_model.name} in #{self.name}: #{matching_services.map(&:name).join(", ")}); you must select one explicitely with a 'use' statement"
                        end
                        selected = main_matching_services.first
                    else
                        selected = matching_services.first
                    end

                    selected
                end

                # Returns the type of the given data service, or raises
                # ArgumentError if no such service is declared on this model
                def data_service_type(name)
                    service = find_data_service(name)
                    if service
                        return service.model
                    end
                    raise ArgumentError, "no service #{name} is declared on #{self}"
                end


                # call-seq:
                #   TaskModel.each_slave_data_service do |name, service|
                #   end
                #
                # Enumerates all services that are slave (i.e. not slave of other
                # services)
                def each_slave_data_service(master_service, &block)
                    each_data_service(nil).
                        find_all { |name, service| service.master == master_service }.
                        map { |name, service| [service.name, service] }.
                        each(&block)
                end


                # call-seq:
                #   TaskModel.each_root_data_service do |name, source_model|
                #   end
                #
                # Enumerates all services that are root (i.e. not slave of other
                # services)
                def each_root_data_service(&block)
                    each_data_service(nil).
                        find_all { |name, srv| srv.master? }.
                        each(&block)
                end
            end

            # Returns true if +self+ can replace +target_task+ in the plan. The
            # super() call checks graph-declared dependencies (i.e. that all
            # dependencies that +target_task+ meets are also met by +self+.
            #
            # This method checks that +target_task+ and +self+ do not represent
            # two different data services
            def can_merge?(target_task)
                return false if !super
                return if !target_task.kind_of?(DataService)

                # Check that for each data service in +target_task+, we can
                # allocate a corresponding service in +self+
                each_service_merge_candidate(target_task) do |selected_source_name, other_service, self_services|
                    if self_services.empty?
                        Engine.debug "cannot merge #{target_task} into #{self} as"
                        Engine.debug "  no candidates for #{other_service}"
                        return false
                    end
                end
                true
            end

            # Replace +merged_task+ by +self+, possibly modifying +self+ so that
            # it is possible.
            def merge(merged_task)
                connection_mappings = Hash.new

                # First thing to do is reassign data services from the merged
                # task into ourselves. Note that we do that only for services
                # that are actually in use.
                each_service_merge_candidate(merged_task) do |selected_source_name, other_service, self_services|
                    if self_services.empty?
                        raise SpecError, "trying to merge #{merged_task} into #{self}, but that seems to not be possible"
                    elsif self_services.size > 1
                        raise Ambiguous, "merging #{self} and #{merged_task} is ambiguous: the #{self_services.map(&:short_name).join(", ")} data services could be used"
                    end

                    # "select" one service to use to handle other_name
                    target_service = self_services.pop
                    # set the argument
                    if selected_source_name && arguments["#{target_service.name}_name"] != selected_source_name
                        arguments["#{target_service.name}_name"] = selected_source_name
                    end

                    # What we also need to do is map port names from the ports
                    # in +merged_task+ into the ports in +self+. We do that by
                    # moving the connections explicitely from +merged_task+ onto
                    # +self+
                    merged_mappings = other_service.port_mappings_for_task.dup
                    new_mappings    = target_service.port_mappings_for_task.dup

                    new_mappings.each do |from, to|
                        from = merged_mappings.delete(from) || from
                        connection_mappings[from] = to
                    end
                    merged_mappings.each do |from, to|
                        connection_mappings[to] = from
                    end
                end

                merged_task.each_source do |source_task|
                    connections = source_task[merged_task, Flows::DataFlow]
                    new_connections = Hash.new
                    connections.each do |(from, to), policy|
                        to = connection_mappings[to] || to
                        new_connections[[from, to]] = policy
                    end
                    Engine.debug do
                        Engine.debug "moving input connections of #{merged_task}"
                        Engine.debug "  => #{source_task} onto #{self}"
                        Engine.debug "  mappings: #{connection_mappings}"
                        Engine.debug "  old:"
                        connections.each do |(from, to), policy|
                            Engine.debug "    #{from} => #{to} (#{policy})"
                        end
                        Engine.debug "  new:"
                        new_connections.each do |(from, to), policy|
                            Engine.debug "    #{from} => #{to} (#{policy})"
                        end
                        break
                    end
                    source_task.connect_ports(self, new_connections)
                end
                merged_task.each_sink do |sink_task, connections|
                    new_connections = Hash.new
                    connections.each do |(from, to), policy|
                        from = connection_mappings[from] || from
                        new_connections[[from, to]] = policy
                    end

                    Engine.debug do
                        Engine.debug "moving output connections of #{merged_task}"
                        Engine.debug "  => #{sink_task}"
                        Engine.debug "  onto #{self}"
                        Engine.debug "  mappings: #{connection_mappings}"
                        Engine.debug "  old:"
                        connections.each do |(from, to), policy|
                            Engine.debug "    #{from} => #{to} (#{policy})"
                        end
                        Engine.debug "  new:"
                        new_connections.each do |(from, to), policy|
                            Engine.debug "    #{from} => #{to} (#{policy})"
                        end
                        break
                    end
                    self.connect_ports(sink_task, new_connections)
                end
                Flows::DataFlow.remove(merged_task)

                super
            end

            # Returns true if at least one port of the given service (designated
            # by its name) is connected to something.
            def using_data_service?(source_name)
                service = model.find_data_service(source_name)
                inputs  = service.each_input_port.map(&:name)
                outputs = service.each_output_port.map(&:name)

                each_source do |output|
                    description = output[self, Flows::DataFlow]
                    if description.any? { |(_, to), _| inputs.include?(to) }
                        return true
                    end
                end
                each_sink do |input, description|
                    if description.any? { |(from, _), _| outputs.include?(from) }
                        return true
                    end
                end
                false
            end

            # Finds the data sources on +other_task+ that have been selected
            # (i.e. the sources that have been assigned to a particular source
            # on the system). Yields it along with a data source on +self+ in
            # which it can be merged, either because the source is assigned as
            # well to the same device, or because it is not assigned yet
            def each_service_merge_candidate(other_task) # :nodoc:
                other_task.model.each_root_data_service do |name, other_service|
                    other_selection = other_task.selected_data_source(other_service)

                    self_selection = nil
                    available_services = model.each_data_service.find_all do |self_name, self_service|
                        self_selection = selected_data_source(self_service)
                        self_service.model.fullfills?(other_service.model) &&
                            (!self_selection || !other_selection || self_selection == other_selection)
                    end

                    yield(other_selection, other_service, available_services.map(&:last))
                end
            end

            extend ClassExtension
        end

        # Module that represents the device drivers in the task models. It
        # defines the methods that are available on task instances. For
        # methods that are available at the task model level, see
        # DataSource::ClassExtension
        module DataSource
            @name = "Orocos::RobyPlugin::DataSource"

            module ClassExtension
                # Enumerate all the data sources that are defined on this
                # component model
                def each_master_data_source(&block)
                    each_root_data_service.
                        find_all { |_, srv| srv.model < DataSource }.
                        map(&:last).
                        each(&block)
                end
            end

            # Enumerates the devices that are mapped to this component
            #
            # It yields the data service and the device model
            def each_device_name
                if !block_given?
                    return enum_for(:each_device_name)
                end

                seen = Set.new
                model.each_master_data_source do |srv|
                    # Slave devices have the same name than the master device,
                    # so no need to list them
                    next if !srv.master?

                    device_name = arguments["#{srv.name}_name"]
                    if device_name && !seen.include?(device_name)
                        seen << device_name
                        yield(srv, device_name)
                    end
                end
            end

            # Enumerates the MasterDeviceInstance and/or SlaveDeviceInstance
            # objects that are mapped to this task context
            #
            # It yields the data service and the device model
            #
            # See also #each_device_name
            def each_device
                if !block_given?
                    return enum_for(:each_device)
                end

                each_device_name do |service, device_name|
                    if !(device = robot.devices[device_name])
                        raise SpecError, "#{self} attaches device #{device_name} to #{service.full_name}, but #{device_name} is not a known device"
                    end

                    yield(service, device)
                end
            end

            # Returns either the MasterDeviceInstance or SlaveDeviceInstance
            # that represents the device tied to this component.
            #
            # If +subname+ is given, it has to be the corresponding data service
            # name. It is optional only if there is only one device attached to
            # this component
            def robot_device(subname = nil)
                devices = model.each_device.to_a
                if !subname
                    if devices.empty?
                        raise ArgumentError, "#{self} is not attached to any device"
                    elsif devices.size > 1
                        raise ArgumentError, "#{self} handles more than one device, you must specify one explicitely"
                    end
                else
                    devices = devices.find_all { |srv, _| srv.full_name == subname }
                    if devices.empty?
                        raise ArgumentError, "there is no data service called #{subname} on #{self}"
                    end
                end
                data_source, device = devices.first
                device
            end

            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                Engine.debug { "initial port dynamics on #{self} (data source)" }

                internal_trigger_activity =
                    (orogen_spec.activity_type.name == "FileDescriptorActivity")

                if !internal_trigger_activity
                    Engine.debug "  is NOT triggered internally"
                    return result
                end

                triggering_devices = each_device.to_a

                Engine.debug do
                    Engine.debug "  is triggered internally"
                    Engine.debug "  attached devices: #{triggering_devices.map(&:last).map(&:name).join(", ")}"
                    break
                end

                triggering_devices.each do |service, device|
                    Engine.debug { "  #{device.name}: #{device.period} #{device.burst}" }
                    device_dynamics = PortDynamics.new(device.name, 1)
                    device_dynamics.add_trigger(device.name, device.period, 1)
                    device_dynamics.add_trigger(device.name + "-burst", 0, device.burst)

                    task_dynamics.merge(device_dynamics)
                    service.each_output_port do |out_port|
                        out_port.triggered_on_update = false
                        port_name = out_port.name
                        port_dynamics = (result[port_name] ||= PortDynamics.new("#{self.orocos_name}.#{out_port.name}", out_port.sample_size))
                        port_dynamics.merge(device_dynamics)
                    end
                end

                result
            end

            include DataService

            def self.to_s # :nodoc:
                "#<DataSource: #{name}>"
            end

            @name = "DataSource"
            module ModuleExtension
                def task_model
                    model = super
                    model.name = "#{name}DataSourceTask"
                    model
                end
            end
            extend ModuleExtension
        end

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBusDriver
            @name = "Orocos::RobyPlugin::ComBusDriver"
            # Communication busses are also device drivers
            include DataSource

            def self.to_s # :nodoc:
                "#<ComBusDriver: #{name}>"
            end

            attribute(:port_to_device) { Hash.new { |h, k| h[k] = Array.new } }

            def self.new_submodel(model, options = Hash.new)
                bus_options, options = Kernel.filter_options options,
                    :override_policy => true, :message_type => nil

                model = super(model, options)
                model.class_eval <<-EOD
                module ModuleExtension
                    def override_policy?
                        #{bus_options[:override_policy]}
                    end
                    def message_type
                        \"#{bus_options[:message_type]}\" || (super if defined? super)
                    end
                end
                extend ModuleExtension
                EOD
                model
            end

            def each_attached_device(&block)
                result = ValueSet.new
                each_connected_device do |_, devices|
                    result |= devices.to_value_set
                end
                result.each(&block)
            end

            # Finds out what output port serves what devices by looking at what
            # tasks it is connected.
            #
            # Indeed, for communication busses, the device model is determined
            # by the sink port of output connections.
            def each_connected_device(&block)
                if !block_given?
                    return enum_for(:each_connected_device)
                end

                each_concrete_output_connection do |source_port, sink_port, sink_task|
                    devices = port_to_device[source_port].
                        map do |d_name|
                            if !(device = robot.devices[d_name])
                                raise ArgumentError, "#{self} refers to device #{d_name} for port #{source_port}, but there is no such device"
                            end
                            device
                        end

                    yield(source_port, devices)
                end
            end

            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result = super
                end

                by_device = Hash.new
                each_connected_device do |port, devices|
                    dynamics = PortDynamics.new("#{self.orocos_name}.#{port}", devices.map(&:sample_size).inject(&:+))
                    devices.each do |dev|
                        dynamics.add_trigger(dev.name, dev.period, 1)
                        dynamics.add_trigger(dev.name, dev.period * dev.burst, dev.burst)
                    end
                    result[port] = dynamics
                end

                result
            end

            # The output port name for the +bus_name+ device attached on this
            # bus
            def output_name_for(bus_name)
                bus_name
            end

            # The input port name for the +bus_name+ device attached on this bus
            def input_name_for(bus_name)
                "w#{bus_name}"
            end
        end
    end
end


