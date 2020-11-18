# Utility methods for interacting with POSIX objects; mostly user and group
module Puppet::Util::POSIX
  require 'ffi'
  module GrpLibC
    extend FFI::Library
    ffi_lib FFI::Library::LIBC
    begin
      attach_function :getgrouplist, [:string, :int, :pointer, :pointer], :int
    rescue FFI::NotFoundError => e
      puts e.message
    end

    def self.user_groups(user)
      gid = Puppet::Etc.getpwnam(user).gid
      ngroups_ptr = FFI::MemoryPointer.new(:int)
      ngroups = 16
      ngroups_ptr.write_int(ngroups)
      groups_ptr = FFI::MemoryPointer.new(:uint, ngroups)

      # getgrouplist updates ngroups_ptr to num required.
      ret = GrpLibC.getgrouplist(user, gid, groups_ptr, ngroups_ptr)

      # # FIXME: some systems (like Darwin) have a bug where they
      # # never increase ngroups_ptr
      # while ret < 0
      #   if (ngroups == ngroups_ptr.get_int(0))
      #     ngroups *= 2;
      #     ngroups_ptr.write_int(ngroups)
      #   end
      #   groups_ptr.free if groups_ptr
      #   groups_ptr = FFI::MemoryPointer.new(:uint, ngroups_ptr.get_int(0))
      #   ret = GrpLibC.getgrouplist(user, gid, groups_ptr, ngroups_ptr)
      # end
      if ret < 0
        groups_ptr.free if groups_ptr
        groups_ptr = FFI::MemoryPointer.new(:uint, ngroups_ptr.get_int(0))
        ret = GrpLibC.getgrouplist(user, gid, groups_ptr, ngroups_ptr)
      end

      if ret >= 0
        gids = groups_ptr.get_array_of_uint(0, ngroups_ptr.get_int(0))
        # by Puppet definition, primary group should not be listed
        gids.reject { |g| g == gid }.map { |g| Puppet::Etc.getgrgid(g).name }
      end
    end
  end

  # This is a list of environment variables that we will set when we want to override the POSIX locale
  LOCALE_ENV_VARS = ['LANG', 'LC_ALL', 'LC_MESSAGES', 'LANGUAGE',
                           'LC_COLLATE', 'LC_CTYPE', 'LC_MONETARY', 'LC_NUMERIC', 'LC_TIME']

  # This is a list of user-related environment variables that we will unset when we want to provide a pristine
  # environment for "exec" runs
  USER_ENV_VARS = ['HOME', 'USER', 'LOGNAME']

  class << self
    # Returns an array of all the groups that the user's a member of.
    def groups_of(user)
      begin
        groups = GrpLibC.user_groups(user)
      rescue => e
        Puppet.debug e.message
        Puppet.debug 'fallback to Puppet::Etc.group'
        groups = []
        Puppet::Etc.group do |group|
          groups << group.name if group.mem.include?(user)
        end
      end

      uniq_groups = groups.uniq
      if uniq_groups != groups
        Puppet.debug(_('Removing any duplicate group entries'))
      end

      uniq_groups
    end
  end

  # Retrieve a field from a POSIX Etc object.  The id can be either an integer
  # or a name.  This only works for users and groups.  It's also broken on
  # some platforms, unfortunately, which is why we fall back to the other
  # method search_posix_field in the gid and uid methods if a sanity check
  # fails
  def get_posix_field(space, field, id)
    raise Puppet::DevError, _("Did not get id from caller") unless id

    if id.is_a?(Integer)
      if id > Puppet[:maximum_uid].to_i
        Puppet.err _("Tried to get %{field} field for silly id %{id}") % { field: field, id: id }
        return nil
      end
      method = methodbyid(space)
    else
      method = methodbyname(space)
    end

    begin
      return Etc.send(method, id).send(field)
    rescue NoMethodError, ArgumentError => e
      Puppet.debug("Etc.#{method} failed, called with id: #{id}, for field: #{field}, error: #{e.class}: #{e.message}")
      # ignore it; we couldn't find the object
      return nil
    end
  end

  # A degenerate method of retrieving name/id mappings.  The job of this method is
  # to retrieve all objects of a certain type, search for a specific entry
  # and then return a given field from that entry.
  def search_posix_field(type, field, id)
    idmethod = idfield(type)
    integer = false
    if id.is_a?(Integer)
      integer = true
      if id > Puppet[:maximum_uid].to_i
        Puppet.err _("Tried to get %{field} field for silly id %{id}") % { field: field, id: id }
        return nil
      end
    end

    Etc.send(type) do |object|
      if integer and object.send(idmethod) == id
        return object.send(field)
      elsif object.name == id
        return object.send(field)
      end
    end

    # Apparently the group/passwd methods need to get reset; if we skip
    # this call, then new users aren't found.
    case type
    when :passwd; Etc.send(:endpwent)
    when :group; Etc.send(:endgrent)
    end
    nil
  end

  # Determine what the field name is for users and groups.
  def idfield(space)
    case space.intern
    when :gr, :group; return :gid
    when :pw, :user, :passwd; return :uid
    else
      raise ArgumentError.new(_("Can only handle users and groups"))
    end
  end

  # Determine what the method is to get users and groups by id
  def methodbyid(space)
    case space.intern
    when :gr, :group; return :getgrgid
    when :pw, :user, :passwd; return :getpwuid
    else
      raise ArgumentError.new(_("Can only handle users and groups"))
    end
  end

  # Determine what the method is to get users and groups by name
  def methodbyname(space)
    case space.intern
    when :gr, :group; return :getgrnam
    when :pw, :user, :passwd; return :getpwnam
    else
      raise ArgumentError.new(_("Can only handle users and groups"))
    end
  end

  # Get the GID
  def gid(group)
      get_posix_value(:group, :gid, group)
  end

  # Get the UID
  def uid(user)
      get_posix_value(:passwd, :uid, user)
  end

  private

  # Get the specified id_field of a given field (user or group),
  # whether an ID name is provided
  def get_posix_value(location, id_field, field)
    begin
      field = Integer(field)
    rescue ArgumentError
      # pass
    end
    if field.is_a?(Integer)
      name = get_posix_field(location, :name, field)
      return nil unless name
      id = get_posix_field(location, id_field, name)
      check_value = id
    else
      id = get_posix_field(location, id_field, field)
      return nil unless id
      name = get_posix_field(location, :name, id)
      check_value = name
    end

    if check_value != field
      check_value_id = get_posix_field(location, id_field, check_value)

      if id == check_value_id
        Puppet.debug("Multiple entries found for resource: '#{location}' with #{id_field}: #{id}")
        return id
      else
        Puppet.debug("The value retrieved: '#{check_value}' is different than the required state: '#{field}', fallback to search in all groups")
        return search_posix_field(location, id_field, field)
      end
    else
      return id
    end
  end
end

