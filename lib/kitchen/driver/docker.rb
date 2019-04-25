# -*- encoding: utf-8 -*-
#
# Copyright (C) 2014, Sean Porter
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'kitchen'
require 'json'
require 'securerandom'
require 'uri'
require 'net/ssh'
require 'tempfile'
require 'shellwords'
require 'base64'
require 'pathname'

require 'kitchen/driver/base'

require_relative './docker/erb'

module Kitchen
  module Driver
    # Docker driver for Kitchen.
    #
    # @author Sean Porter <portertech@gmail.com>
    class Docker < Kitchen::Driver::Base
      include ShellOut

      default_config :binary,        'docker'
      default_config :socket,        ENV['DOCKER_HOST'] || 'unix:///var/run/docker.sock'
      default_config :privileged,    false
      default_config :cap_add,       nil
      default_config :cap_drop,      nil
      default_config :security_opt,  nil
      default_config :use_cache,     true
      default_config :remove_images, false
      default_config :run_command,   '/usr/sbin/sshd -D -o UseDNS=no -o UsePAM=no -o PasswordAuthentication=yes ' +
                                     '-o UsePrivilegeSeparation=no -o PidFile=/tmp/sshd.pid'
      default_config :username,      'kitchen'
      default_config :tls,           false
      default_config :tls_verify,    false
      default_config :tls_cacert,    nil
      default_config :tls_cert,      nil
      default_config :tls_key,       nil
      default_config :publish_all,   false
      default_config :wait_for_sshd, true
      default_config :private_key,   File.join(Dir.pwd, '.kitchen', 'docker_id_rsa')
      default_config :public_key,    File.join(Dir.pwd, '.kitchen', 'docker_id_rsa.pub')
      default_config :build_options, nil
      default_config :run_options,   nil
      default_config :use_internal_docker_network, false
      default_config :build_tempdir, Dir.pwd

      default_config :use_sudo, false

      default_config :image do |driver|
        driver.default_image
      end

      default_config :platform do |driver|
        driver.default_platform
      end

      default_config :disable_upstart, true

      default_config :build_context do |driver|
        !driver.remote_socket?
      end

      default_config :instance_name do |driver|
        # Borrowed from kitchen-rackspace
        [
          driver.instance.name.gsub(/\W/, ''),
          (Etc.getlogin || 'nologin').gsub(/\W/, ''),
          Socket.gethostname.gsub(/\W/, '')[0..20],
          Array.new(8) { rand(36).to_s(36) }.join
        ].join('-')
      end

      MUTEX_FOR_SSH_KEYS = Mutex.new

      def verify_dependencies
        run_command("#{config[:binary]} >> #{dev_null} 2>&1", quiet: true, use_sudo: config[:use_sudo])
        rescue
          raise UserError,
          'You must first install the Docker CLI tool https://www.docker.com/get-started'
      end

      def dev_null
        case RbConfig::CONFIG["host_os"]
        when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
          "NUL"
        else
          "/dev/null"
        end
      end

      def default_image
        platform, release = instance.platform.name.split('-')
        if platform == 'centos' && release
          release = 'centos' + release.split('.').first
        end
        release ? [platform, release].join(':') : platform
      end

      def default_platform
        instance.platform.name.split('-').first
      end

      def create(state)
        generate_keys
        state[:username] = config[:username]
        state[:ssh_key] = config[:private_key]
        state[:image_id] = build_image(state) unless state[:image_id]
        state[:container_id] = run_container(state) unless state[:container_id]
        state[:hostname] = 'localhost'
        if remote_socket?
          state[:hostname] = socket_uri.host
        elsif config[:use_internal_docker_network]
          state[:hostname] = container_ip(state)
        end
        state[:port] = container_ssh_port(state)
        if config[:wait_for_sshd]
          instance.transport.connection(state) do |conn|
            conn.wait_until_ready
          end
        end
      end

      def destroy(state)
        rm_container(state) if container_exists?(state)
        if config[:remove_images] && state[:image_id]
          rm_image(state) if image_exists?(state)
        end
      end

      def remote_socket?
        config[:socket] ? socket_uri.scheme == 'tcp' : false
      end

      protected

      def socket_uri
        URI.parse(config[:socket])
      end

      def docker_command(cmd, options={})
        docker = config[:binary].dup
        docker << " -H #{config[:socket]}" if config[:socket]
        docker << " --tls" if config[:tls]
        docker << " --tlsverify" if config[:tls_verify]
        docker << " --tlscacert=#{config[:tls_cacert]}" if config[:tls_cacert]
        docker << " --tlscert=#{config[:tls_cert]}" if config[:tls_cert]
        docker << " --tlskey=#{config[:tls_key]}" if config[:tls_key]
        run_command("#{docker} #{cmd}", options.merge({
          quiet: !logger.debug?,
          use_sudo: config[:use_sudo],
          log_subject: Thor::Util.snake_case(self.class.to_s),
        }))
      end

      def generate_keys
        MUTEX_FOR_SSH_KEYS.synchronize do
          if !File.exist?(config[:public_key]) || !File.exist?(config[:private_key])
            private_key = OpenSSL::PKey::RSA.new(2048)
            blobbed_key = Base64.encode64(private_key.to_blob).gsub("\n", '')
            public_key = "ssh-rsa #{blobbed_key} kitchen_docker_key"
            File.open(config[:private_key], 'w') do |file|
              file.write(private_key)
              file.chmod(0600)
            end
            File.open(config[:public_key], 'w') do |file|
              file.write(public_key)
              file.chmod(0600)
            end
          end
        end
      end

      def build_dockerfile
        from = "FROM #{config[:image]}"

        env_variables = ''
        if config[:http_proxy]
          env_variables << "ENV http_proxy #{config[:http_proxy]}\n"
          env_variables << "ENV HTTP_PROXY #{config[:http_proxy]}\n"
        end

        if config[:https_proxy]
          env_variables << "ENV https_proxy #{config[:https_proxy]}\n"
          env_variables << "ENV HTTPS_PROXY #{config[:https_proxy]}\n"
        end

        if config[:no_proxy]
          env_variables << "ENV no_proxy #{config[:no_proxy]}\n"
          env_variables << "ENV NO_PROXY #{config[:no_proxy]}\n"
        end

        platform = case config[:platform]
        when 'debian', 'ubuntu'
          disable_upstart = <<-eos
            RUN [ ! -f "/sbin/initctl" ] || dpkg-divert --local --rename --add /sbin/initctl && ln -sf /bin/true /sbin/initctl
          eos
          packages = <<-eos
            ENV DEBIAN_FRONTEND noninteractive
            ENV container docker
            RUN apt-get update
            RUN apt-get install -y sudo openssh-server curl lsb-release
          eos
          config[:disable_upstart] ? disable_upstart + packages : packages
        when 'rhel', 'centos', 'oraclelinux', 'amazonlinux'
          <<-eos
            ENV container docker
            RUN yum clean all
            RUN yum install -y sudo openssh-server openssh-clients which curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
          eos
        when 'fedora'
          <<-eos
            ENV container docker
            RUN dnf clean all
            RUN dnf install -y sudo openssh-server openssh-clients which curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
          eos
        when 'opensuse/tumbleweed', 'opensuse/leap', 'opensuse', 'sles'
          <<-eos
            ENV container docker
            RUN zypper install -y sudo openssh which curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
          eos
        when 'arch'
          # See https://bugs.archlinux.org/task/47052 for why we
          # blank out limits.conf.
          <<-eos
            RUN pacman --noconfirm -Sy archlinux-keyring
            RUN pacman-db-upgrade
            RUN pacman --noconfirm -Syu openssl openssh sudo curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -A -t rsa -f /etc/ssh/ssh_host_rsa_key
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -A -t dsa -f /etc/ssh/ssh_host_dsa_key
            RUN echo >/etc/security/limits.conf
          eos
        when 'gentoo'
          <<-eos
            RUN emerge --sync
            RUN emerge net-misc/openssh app-admin/sudo
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -A -t rsa -f /etc/ssh/ssh_host_rsa_key
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -A -t dsa -f /etc/ssh/ssh_host_dsa_key
          eos
        when 'gentoo-paludis'
          <<-eos
            RUN cave sync
            RUN cave resolve -zx net-misc/openssh app-admin/sudo
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -A -t rsa -f /etc/ssh/ssh_host_rsa_key
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -A -t dsa -f /etc/ssh/ssh_host_dsa_key
          eos
        else
          raise ActionFailed,
          "Unknown platform '#{config[:platform]}'"
        end

        username = config[:username]
        public_key = IO.read(config[:public_key]).strip
        homedir = username == 'root' ? '/root' : "/home/#{username}"

        base = <<-eos
          RUN if ! getent passwd #{username}; then \
                useradd -d #{homedir} -m -s /bin/bash -p '*' #{username}; \
              fi
          RUN echo "#{username} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
          RUN echo "Defaults !requiretty" >> /etc/sudoers
          RUN mkdir -p #{homedir}/.ssh
          RUN chown -R #{username} #{homedir}/.ssh
          RUN chmod 0700 #{homedir}/.ssh
          RUN touch #{homedir}/.ssh/authorized_keys
          RUN chown #{username} #{homedir}/.ssh/authorized_keys
          RUN chmod 0600 #{homedir}/.ssh/authorized_keys
          RUN mkdir -p /run/sshd
        eos
        custom = ''
        Array(config[:provision_command]).each do |cmd|
          custom << "RUN #{cmd}\n"
        end
        ssh_key = "RUN echo #{Shellwords.escape(public_key)} >> #{homedir}/.ssh/authorized_keys"
        # Empty string to ensure the file ends with a newline.
        [from, env_variables, platform, base, custom, ssh_key, ''].join("\n")
      end

      def dockerfile
        if config[:dockerfile]
          template = IO.read(File.expand_path(config[:dockerfile]))
          context = DockerERBContext.new(config.to_hash)
          ERB.new(template).result(context.get_binding)
        else
          build_dockerfile
        end
      end

      def parse_image_id(output)
        output.each_line do |line|
          if line =~ /image id|build successful|successfully built/i
            return line.split(/\s+/).last
          end
        end
        raise ActionFailed,
          'Could not parse Docker build output for image ID'
      end

      def build_image(state)
        cmd = "build"
        cmd << " --no-cache" unless config[:use_cache]
        extra_build_options = config_to_options(config[:build_options])
        cmd << " #{extra_build_options}" unless extra_build_options.empty?
        dockerfile_contents = dockerfile
        build_context = config[:build_context] ? '.' : '-'
        file = Tempfile.new('Dockerfile-kitchen', Pathname.pwd + config[:build_tempdir])
        output = begin
          file.write(dockerfile)
          file.close
          docker_command("#{cmd} -f #{Shellwords.escape(dockerfile_path(file))} #{build_context}", :input => dockerfile_contents)
        ensure
          file.close unless file.closed?
          file.unlink
        end
        parse_image_id(output)
      end

      def parse_container_id(output)
        container_id = output.chomp
        unless [12, 64].include?(container_id.size)
          raise ActionFailed,
          'Could not parse Docker run output for container ID'
        end
        container_id
      end

      def build_run_command(image_id)
        cmd = "run -d -p 22"
        Array(config[:forward]).each {|port| cmd << " -p #{port}"}
        Array(config[:dns]).each {|dns| cmd << " --dns #{dns}"}
        Array(config[:add_host]).each {|host, ip| cmd << " --add-host=#{host}:#{ip}"}
        Array(config[:volume]).each {|volume| cmd << " -v #{volume}"}
        Array(config[:volumes_from]).each {|container| cmd << " --volumes-from #{container}"}
        Array(config[:links]).each {|link| cmd << " --link #{link}"}
        Array(config[:devices]).each {|device| cmd << " --device #{device}"}
        cmd << " --name #{config[:instance_name]}" if config[:instance_name]
        cmd << " -P" if config[:publish_all]
        cmd << " -h #{config[:hostname]}" if config[:hostname]
        cmd << " -m #{config[:memory]}" if config[:memory]
        cmd << " -c #{config[:cpu]}" if config[:cpu]
        cmd << " -e http_proxy=#{config[:http_proxy]}" if config[:http_proxy]
        cmd << " -e https_proxy=#{config[:https_proxy]}" if config[:https_proxy]
        cmd << " --privileged" if config[:privileged]
        Array(config[:cap_add]).each {|cap| cmd << " --cap-add=#{cap}"} if config[:cap_add]
        Array(config[:cap_drop]).each {|cap| cmd << " --cap-drop=#{cap}"} if config[:cap_drop]
        Array(config[:security_opt]).each {|opt| cmd << " --security-opt=#{opt}"} if config[:security_opt]
        extra_run_options = config_to_options(config[:run_options])
        cmd << " #{extra_run_options}" unless extra_run_options.empty?
        cmd << " #{image_id} #{config[:run_command]}"
        cmd
      end

      def run_container(state)
        cmd = build_run_command(state[:image_id])
        output = docker_command(cmd)
        parse_container_id(output)
      end

      def container_exists?(state)
        state[:container_id] && !!docker_command("top #{state[:container_id]}") rescue false
      end

      def image_exists?(state)
        state[:image_id] && !!docker_command("docker inspect --type=image #{state[:image_id]}") rescue false
      end

      def parse_container_ssh_port(output)
        begin
          _host, port = output.split(':')
          port.to_i
        rescue
          raise ActionFailed,
            'Could not parse Docker port output for container SSH port'
        end
      end

      def container_ssh_port(state)
        begin
          if config[:use_internal_docker_network]
            return 22
          end
          output = docker_command("port #{state[:container_id]} 22/tcp")
          parse_container_ssh_port(output)
        rescue
          raise ActionFailed,
          'Docker reports container has no ssh port mapped'
        end
      end

      def container_ip(state)
        begin
          cmd = "inspect --format '{{ .NetworkSettings.IPAddress }}'"
          cmd << " #{state[:container_id]}"
          docker_command(cmd).strip
        rescue
          raise ActionFailed,
          'Error getting internal IP of Docker container'
        end
      end

      def rm_container(state)
        container_id = state[:container_id]
        docker_command("stop -t 0 #{container_id}")
        docker_command("rm #{container_id}")
      end

      def rm_image(state)
        image_id = state[:image_id]
        docker_command("rmi #{image_id}")
      end

      # Convert the config input for `:build_options` or `:run_options` in to a
      # command line string for use with Docker.
      #
      # @since 2.5.0
      # @param config [nil, String, Array, Hash] Config data to convert.
      # @return [String]
      def config_to_options(config)
        case config
        when nil
          ''
        when String
          config
        when Array
          config.map {|c| config_to_options(c) }.join(' ')
        when Hash
          config.map {|k, v| Array(v).map {|c| "--#{k}=#{Shellwords.escape(c)}" }.join(' ') }.join(' ')
        end
      end

      def dockerfile_path(file)
        config[:build_context] ? Pathname.new(file.path).relative_path_from(Pathname.pwd).to_s : file.path
      end

    end
  end
end
