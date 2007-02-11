require 'msf/core'

module Msf

###
#
# This class represents the base class for a logical payload.  The framework
# automatically generates payload combinations at runtime which are all
# extended for this Payload as a base class.
#
###
class Payload < Msf::Module

	require 'rex/payloads'

	require 'msf/core/payload/single'
	require 'msf/core/payload/generic'
	require 'msf/core/payload/stager'

	# Platform specific includes
	require 'msf/core/payload/windows'

	##
	#
	# Payload types
	#
	##
	module Type
		#
		# Single payload type.  These types of payloads are self contained and
		# do not go through any staging.
		#
		Single = (1 << 0)
		
		#
		# The stager half of a staged payload.  Its responsibility in life is to
		# read in the stage and execute it.
		#
		Stager = (1 << 1)

		#
		# The stage half of a staged payload.  This payload performs whatever
		# arbitrary task it's designed to do, possibly making use of the same
		# connection that the stager used to read the stage in on, if
		# applicable.
		#
		Stage  = (1 << 2)
	end

	#
	# Creates an instance of a payload module using the supplied information.
	#
	def initialize(info = {})
		super

		# Update the module info hash with the connection type
		# that is derived from the handler for this payload.  This is
		# used for compatibility filtering purposes.
		self.module_info['ConnectionType'] = connection_type
	end

	##
	#
	# Accessors
	#
	##

	#
	# Returns MODULE_PAYLOAD to indicate that this is a payload module.
	#
	def self.type
		return MODULE_PAYLOAD
	end

	#
	# Returns MODULE_PAYLOAD to indicate that this is a payload module.
	#
	def type
		return MODULE_PAYLOAD
	end

	#
	# Returns the string of bad characters for this payload, if any.
	#
	def badchars
		return self.module_info['BadChars']
	end

	#
	# The list of registers that should be saved by any NOP generators or
	# encoders, if possible.
	#
	def save_registers
		return self.module_info['SaveRegisters']
	end

	#
	# Returns the type of payload, either single or staged.  Stage is
	# the default because singles and stagers are encouraged to include
	# the Single and Stager mixin which override the payload_type.
	#
	def payload_type
		return Type::Stage
	end

	#
	# This method returns whether or not this payload uses staging.
	#
	def staged?
		(payload_type == Type::Stager or payload_type == Type::Stage)
	end

	#
	# Returns the payload's size.  If the payload is staged, the size of the
	# first stage is returned.
	#
	def size
		return (generate() || '').length
	end

	#
	# Returns the raw payload that has not had variable substitution occur.
	#
	def payload
		return module_info['Payload']['Payload']
	end

	#
	# Returns the offsets to variables that must be substitute, if any.
	#
	def offsets
		return module_info['Payload']['Offsets']
	end

	#
	# Returns the staging convention that the payload uses, if any.  This is
	# used to make sure that only compatible stagers and stages are built
	# (where assumptions are made about register/environment initialization
	# state and hand-off).
	#
	def convention
		module_info['Convention']
	end

	#
	# Returns the module's connection type, such as reverse, bind, noconn,
	# or whatever else the case may be.
	#
	def connection_type
		handler_klass.general_handler_type
	end

	#
	# Returns the method used by the payload to resolve symbols for the purpose
	# of calling functions, such as ws2ord.
	#
	def symbol_lookup
		module_info['SymbolLookup']
	end

	#
	# Checks to see if the supplied convention is compatible with this
	# payload's convention.
	#
	def compatible_convention?(conv)
		# If we ourself don't have a convention or our convention is equal to
		# the one supplied, then we know we are compatible.
		if ((self.convention == nil) or
		    (self.convention == conv))
			true
		# On the flip side, if we are a stager and the supplied convention is
		# nil, then we know it's compatible.
		elsif ((payload_type == Type::Stager) and
		       (conv == nil))
			true
		# Otherwise, the conventions don't match in some way or another, and as
		# such we deem ourself as not being compatible with the supplied
		# convention.
		else
			false
		end
	end

	#
	# Return the connection associated with this payload, or none if there
	# isn't one.
	#
	def handler_klass
		return module_info['Handler'] || Msf::Handler::None
	end

	#
	# Returns the session class that is associated with this payload and will
	# be used to create a session as necessary.
	#
	def session
		return module_info['Session']
	end

	##
	#
	# Generation & variable substitution
	#
	##

	#
	# Generates the payload and returns the raw buffer to the caller.
	#
	def generate
		raw = payload.dup

		# If the payload is generated and there are offsets to substitute,
		# do that now.
		if (raw and offsets)
			substitute_vars(raw, offsets)
		end

		return raw
	end

	#
	# Substitutes variables with values from the module's datastore in the
	# supplied raw buffer for a given set of named offsets.  For instance,
	# RHOST is substituted with the RHOST value from the datastore which will
	# have been populated by the framework.
	#
	# Supprted packing types:
	#
	# - ADDR (foo.com, 1.2.3.4)
	# - HEX  (0x12345678, "\x41\x42\x43\x44")
	# - RAW  (raw bytes)
	#
	def substitute_vars(raw, offsets)
		offsets.each_pair { |name, info|
			offset, pack = info

			# Give the derived class a chance to substitute this variable
			next if (replace_var(raw, name, offset, pack) == true)

			# Now it's our turn...
			if ((val = datastore[name]))
				if (pack == 'ADDR')
					val = Rex::Socket.resolv_nbo(val)
				elsif (pack == 'RAW')
					# Just use the raw value...
				else
					# Check to see if the value is a hex string.  If so, convert
					# it.
					if val.kind_of?(String)
						if val =~ /^\\x/
							val = [ val.gsub(/\\x/, '') ].pack("H*").unpack(pack)[0]
						elsif val =~ /^0x/
							val = val.hex
						end
					end

					# NOTE:
					# Packing assumes integer format at this point, should fix...
					val = [ val.to_i ].pack(pack)	
				end

				# Substitute it
				raw[offset, val.length] = val
			else
				wlog("Missing value for payload offset #{name}, skipping.", 
					'core', LEV_3)
			end
		}
	end

	#
	# Replaces an individual variable in the supplied buffer at an offset
	# using the given pack type.  This is here to allow derived payloads
	# the opportunity to replace advanced variables.
	#
	def replace_var(raw, name, offset, pack)
		return false
	end

	##
	#
	# Shortcut methods for filtering compatible encoders
	# and NOP sleds
	#
	##

	#
	# Returns the array of compatible encoders for this payload instance.
	#
	def compatible_encoders
		encoders = []

		framework.encoders.each_module_ranked(
			'Arch' => self.arch) { |name, mod|
			encoders << [ name, mod ]
		}

		return encoders
	end

	#
	# Returns the array of compatible nops for this payload instance.
	#
	def compatible_nops
		nops = []

		framework.nops.each_module_ranked(
			'Arch' => self.arch) { |name, mod|
			nops << [ name, mod ]
		}

		return nops
	end

	##
	#
	# Event notifications.
	#
	##
	
	#
	# Once an exploit completes and a session has been created on behalf of the
	# payload, the framework will call the payload's on_session notification
	# routine to allow it to manipulate the session prior to handing off
	# control to the user.
	#
	def on_session(session)
	
	
		# If this payload is associated with an exploit, inform the exploit
		# that a session has been created and potentially shut down any 
		# open sockets. This allows active exploits to continue hammering
		# on a service until a session is created.
		if (assoc_exploit)

			# Signal that a new session is created by calling the exploit's
			# on_new_session handler. The default behavior is to set an
			# instance variable, which the exploit will have to check.
			assoc_exploit.on_new_session(session)
			
			# Set the abort sockets flag only if the exploit is not passive
			# and the connection type is not 'find'
			if (
				(assoc_exploit.exploit_type == Exploit::Type::Remote) and
				(assoc_exploit.passive? == false) and
				(connection_type != 'find')
			   )
			   assoc_exploit.abort_sockets
			end

		end

	end

	#
	# This attribute holds the string that should be prepended to the buffer
	# when it's generated.
	#
	attr_accessor :prepend
	#
	# This attribute holds the string that should be appended to the buffer
	# when it's generated.
	#
	attr_accessor :append
	#
	# This attribute holds the string that should be prepended to the encoded
	# version of the payload (in front of the encoder as well).
	#
	attr_accessor :prepend_encoder

	#
	# If this payload is associated with an exploit, the assoc_exploit
	# attribute will point to that exploit instance.
	#
	attr_accessor :assoc_exploit

protected

	##
	#
	# Custom merge operations for payloads
	#
	##

	#
	# Merge the name to prefix the existing one and separate them
	# with a comma
	#
	def merge_name(info, val)
		if (info['Name'])
			info['Name'] = val + ',' + info['Name']
		else
			info['Name'] = val
		end
	end

end

end
