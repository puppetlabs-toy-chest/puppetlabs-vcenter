module Puppet::Modules
  module VCenter
    module ProviderBase

      @doc = "Shared code among vCenter providers."

      def self.included(base)
        # only require RbVmomi when this module gets mixed in
        begin
          require 'rbvmomi'
        rescue LoadError => exc
           msg = "Could not load the required rbvmomi library [#{exc.message}]"
           Puppet.err msg
           error = Puppet::Error.new(msg)
           error.set_backtrace exc.backtrace
           raise error
         end
      end

      # connect to vCenter and get the rootFolder.
      def get_root_folder(connection_url)
        # FIXME handle parsing errors (URI.parse?)
        # TODO handle wrong connection_url?
        # TODO insecure?
        user, pwd, host = connection_url.split(%r{[:@]})
        conn = RbVmomi::VIM.connect(:host => host,
                                    :user => user,
                                    :password => pwd,
                                    :insecure => true)
        conn.serviceInstance.content.rootFolder
      end

      def parse_path(path)
        # FIXME for now path must be in the form of '/foo/bar/last/'
        path[1..path.size-2].split('/')
      end

      # parent_lvs is an array holding the name of each parent level
      # each name corresponds to one Folder/Datacenter/ClusterComputeResource
      # return the last "container" in parent_lvs,
      # the container might have a Folder, a Datacenter, or a Cluster internally
      def find_immediate_parent(root_folder, parent_lvs, error_msg)
        prev_lv = root_folder
        parent_lvs.each do |lv|
          # Ruby trick: can't use prev_lv.class b/c case stmt uses ===
          case prev_lv
          when RbVmomi::VIM::Folder
            current_lv = prev_lv.find(lv)
          when RbVmomi::VIM::Datacenter
            current_lv = prev_lv.hostFolder.find(lv)
          when RbVmomi::VIM::ClusterComputeResource
            # invalid - not expecting
            # Folder/Datacenter/ClusterComputeResource under a ClusterComputeResource
            current_lv = nil
          else
            raise PathNotFoundError.new(error_msg, __LINE__, __FILE__)
          end

          # raise an error if lv isn't found
          unless current_lv
            raise PathNotFoundError.new(error_msg, __LINE__, __FILE__)
          end

          # go one level deeper
          prev_lv = current_lv
        end

        begin
          # may raise exception if the last prev_lv is not
          # a container type (Cluster, Datacenter, or Folder)
          Container.new(prev_lv)
        rescue
          raise PathNotFoundError.new(error_msg, __LINE__, __FILE__)
        end
      end

      class Container
        @doc = "Wrapper type of Folder, Datacenter, or Cluster"
        attr_reader :real_container

        # TODO do this by opening class?
        # TODO or use a dispatcher?

        def initialize real_container
          unless [RbVmomi::VIM::Folder,
                  RbVmomi::VIM::Datacenter,
                  RbVmomi::VIM::ClusterComputeResource].include?(real_container.class)
            raise Puppet::Error.new(
              "Container must be initialized with a Folder, a Datacenter, or a ClusterComputeResource.",
              __LINE__,
              __FILE__)
          end
          @real_container = real_container
        end

        # return the child RbVmomi object, or nil if not found
        def find_child_by_name(child)
          case
          when is_folder?
            @real_container.find(child)
          when is_datacenter?
            @real_container.hostFolder.find(child)
          when is_cluster?
            @real_container.host.each do |host|
              host if host.name = child
            end
          else
            raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
          end
        end

        def children
          case
          when is_folder?
            @real_container.children
          when is_datacenter?
            @real_container.hostFolder.children
          when is_cluster?
            @real_container.host
          else
            raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
          end
        end

        def add_host(host_spec)
          while true
            begin
              case
              when is_folder?
                @real_container.AddStandaloneHost_Task(
                    :spec => host_spec,
                    :addConnected => true).wait_for_completion
              when is_datacenter?
                @real_container.hostFolder.AddStandaloneHost_Task(
                    :spec => host_spec,
                    :addConnected => true).wait_for_completion
              when is_cluster?
                @real_container.AddHost_Task(
                    :spec => host_spec,
                    :asConnected => true).wait_for_completion
              else
                raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
              end
              break
            rescue RbVmomi::VIM::SSLVerifyFault
              host_spec[:sslThumbprint] = $!.fault.thumbprint
            end
          end
        end

        def create_cluster(cluster_name, error_msg)
          case
          when is_folder?
            # may report error if there's no Datacenter in the path
            @real_container.CreateClusterEx(:name => cluster_name, :spec => {})
          when is_datacenter?
            @real_container.hostFolder.CreateClusterEx(:name => cluster_name, :spec => {})
          when is_cluster?
            raise Puppet::Error.new(error_msg, __LINE__, __FILE__)
          else
            raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
          end
        end

        def create_datacenter(dcname, error_msg)
          case
          when is_folder?
            @real_container.CreateDatacenter(:name => dcname)
          when is_datacenter?
            # won't work but we want vCenter to report the error so do it anyway
            @real_container.hostFolder.CreateDatacenter(:name => dcname)
          when is_cluster?
            raise Puppet::Error.new(error_msg, __LINE__, __FILE__)
          else
            raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
          end
        end

        def create_folder(folder_name, error_msg)
          case
          when is_folder?
            @real_container.CreateFolder(:name => folder_name)
          when is_datacenter?
            @real_container.hostFolder.CreateFolder(:name => folder_name)
          when is_cluster?
            raise Puppet::Error.new(error_msg, __LINE__, __FILE__)
          else
            raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
          end
        end

        def destroy_child(child_name, child_class, error_msg)
          child = find_child_by_name(child_name)
          if child.instance_of?(child_class)
            child.Destroy_Task.wait_for_completion
          else
            raise Puppet::Error.new(error_msg, __LINE__, __FILE__)
          end
        end

        def move_host_into(host)
          # TODO host needs to be in maintenance mode
          # when moved out of a cluster
          case
          when is_folder?
            @real_container.MoveIntoFolder_Task(
              :list => [host]).wait_for_completion
          when is_datacenter?
            @real_container.hostFolder.MoveIntoFolder_Task(
              :list => [host]).wait_for_completion
          when is_cluster?
            # need host to be a HostSystem when moving into a Cluster
            if host.instance_of?(RbVmomi::VIM::ComputeResource)
              host = host.host
            elsif host.instance_of?(RbVmomi::VIM::HostSystem)
              # host might already be a HostSystem
              # if it's currently under another cluster
              host = [host]
            else
              raise Puppet::Error.new('Unknown host type.',
                                        __LINE__, __FILE__)
            end
            # there is another similar method called MoveHostInto_Task
            @real_container.MoveInto_Task(
              :host => host).wait_for_completion
          else
            raise Puppet::Error.new('Unknown internal container type.',
                                        __LINE__, __FILE__)
          end
        end

        def is_folder?
          @real_container.instance_of?(RbVmomi::VIM::Folder)
        end

        def is_datacenter?
          @real_container.instance_of?(RbVmomi::VIM::Datacenter)
        end

        def is_cluster?
          @real_container.instance_of?(RbVmomi::VIM::ClusterComputeResource)
        end
      end

      class PathNotFoundError < Puppet::Error
      end

    end
  end
end

