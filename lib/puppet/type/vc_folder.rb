require 'puppet/modules/vcenter/type_base'

Puppet::Type.newtype(:vc_folder) do
  @doc = "Manage vCenter folders."

  ensurable do
    newvalue(:present) do
      provider.create
    end

    newvalue(:absent) do
      provider.destroy
    end

    defaultto(:present)
  end

  newparam(:path) do
    desc "The path to the folder."
    isnamevar

    validate(&Puppet::Modules::VCenter::TypeBase.get_validate_path_block)
    munge(&Puppet::Modules::VCenter::TypeBase.get_munge_path_block)

  end

  newparam(:connection) do
    desc "The connectivity to vCenter."

    # username:password@hostname
    validate(&Puppet::Modules::VCenter::TypeBase.get_validate_connection_block)

  end

  autorequire(:vc_datacenter) do
    # autorequire immediate parent Datacenter
    Puppet::Modules::VCenter::TypeBase.get_immediate_parent(self[:path])
  end

  autorequire(:vc_folder) do
    # autorequrie immediate parent Folder.
    Puppet::Modules::VCenter::TypeBase.get_immediate_parent(self[:path])
  end
end
