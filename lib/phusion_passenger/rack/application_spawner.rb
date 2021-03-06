#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__) + "/../../../vendor/rack-0.9.1/lib"))
require 'rack'

require 'socket'
require 'phusion_passenger/application'
require 'phusion_passenger/events'
require 'phusion_passenger/message_channel'
require 'phusion_passenger/abstract_request_handler'
require 'phusion_passenger/utils'
require 'phusion_passenger/rack/request_handler'

module PhusionPassenger
module Rack

# Class for spawning Rack applications.
class ApplicationSpawner
	include Utils
	
	def self.spawn_application(*args)
		@@instance ||= ApplicationSpawner.new
		@@instance.spawn_application(*args)
	end
	
	# Spawn an instance of the given Rack application. When successful, an
	# Application object will be returned, which represents the spawned
	# application.
	#
	# Raises:
	# - AppInitError: The Rack application raised an exception or called
	#   exit() during startup.
	# - SystemCallError, IOError, SocketError: Something went wrong.
	def spawn_application(app_root, options = {})
		options = sanitize_spawn_options(options)
		
		a, b = UNIXSocket.pair
		pid = safe_fork(self.class.to_s, true) do
			a.close
			
			file_descriptors_to_leave_open = [0, 1, 2, b.fileno]
			NativeSupport.close_all_file_descriptors(file_descriptors_to_leave_open)
			close_all_io_objects_for_fds(file_descriptors_to_leave_open)
			
			run(MessageChannel.new(b), app_root, options)
		end
		b.close
		Process.waitpid(pid) rescue nil
		
		channel = MessageChannel.new(a)
		unmarshal_and_raise_errors(channel, "rack")
		
		# No exception was raised, so spawning succeeded.
		pid, socket_name, socket_type = channel.read
		if pid.nil?
			raise IOError, "Connection closed"
		end
		owner_pipe = channel.recv_io
		return Application.new(@app_root, pid, socket_name,
			socket_type, owner_pipe)
	end

private
	
	def run(channel, app_root, options)
		$0 = "Rack: #{app_root}"
		app = nil
		success = report_app_init_status(channel) do
			ENV['RACK_ENV'] = options["environment"]
			Dir.chdir(app_root)
			if options["lower_privilege"]
				lower_privilege('config.ru', options["lowest_user"])
			end
			app = load_rack_app
		end
		
		if success
			reader, writer = IO.pipe
			begin
				handler = RequestHandler.new(reader, app, options)
				channel.write(Process.pid, handler.socket_name,
					handler.socket_type)
				channel.send_io(writer)
				writer.close
				channel.close
				
				PhusionPassenger.call_event(:starting_worker_process)
				handler.main_loop
			ensure
				channel.close rescue nil
				writer.close rescue nil
				handler.cleanup rescue nil
				PhusionPassenger.call_event(:stopping_worker_process)
			end
		end
	end

	def load_rack_app
		rackup_code = ::File.read("config.ru")
		eval("Rack::Builder.new {( #{rackup_code}\n )}.to_app", TOPLEVEL_BINDING, "config.ru")
	end
end

end # module Rack
end # module PhusionPassenger
