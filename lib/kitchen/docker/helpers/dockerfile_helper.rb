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
require 'kitchen/configurable'

module Kitchen
  module Docker
    module Helpers
      module DockerfileHelper     
        include Configurable

        def dockerfile_platform
          case config[:platform]
          when 'arch'
            arch_platform
          when 'debian', 'ubuntu'
            debian_platform
          when 'fedora'
            fedora_platform
          when 'gentoo'
            gentoo_platform
          when 'gentoo-paludis'
            gentoo_paludis_platform
          when 'opensuse/tumbleweed', 'opensuse/leap', 'opensuse', 'sles'
            opensuse_platform
          when 'rhel', 'centos', 'oraclelinux', 'amazonlinux'
            rhel_platform
          else
            raise ActionFailed, "Unknown platform '#{config[:platform]}'"
          end
        end

        def arch_platform
          # See https://bugs.archlinux.org/task/47052 for why we
          # blank out limits.conf.
          <<-CODE
            RUN pacman --noconfirm -Sy archlinux-keyring
            RUN pacman-db-upgrade
            RUN pacman --noconfirm -Syu openssl openssh sudo curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -A -t rsa -f /etc/ssh/ssh_host_rsa_key
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -A -t dsa -f /etc/ssh/ssh_host_dsa_key
            RUN echo >/etc/security/limits.conf
          CODE
        end

        def debian_platform
          disable_upstart = <<-CODE
            RUN [ ! -f "/sbin/initctl" ] || dpkg-divert --local --rename --add /sbin/initctl \
                && ln -sf /bin/true /sbin/initctl
          CODE
          packages = <<-CODE
            ENV DEBIAN_FRONTEND noninteractive
            ENV container docker
            RUN apt-get update && apt-get install -y sudo openssh-server curl lsb-release
          CODE
          config[:disable_upstart] ? disable_upstart + packages : packages
        end

        def fedora_platform
          <<-CODE
            ENV container docker
            RUN dnf clean all
            RUN dnf install -y sudo openssh-server openssh-clients which curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
          CODE
        end

        def gentoo_platform
          <<-CODE
            RUN emerge-webrsync
            RUN emerge --quiet --noreplace net-misc/openssh app-admin/sudo
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -A -t rsa -f /etc/ssh/ssh_host_rsa_key
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -A -t dsa -f /etc/ssh/ssh_host_dsa_key
          CODE
        end

        def gentoo_paludis_platform
          <<-CODE
            RUN cave sync
            RUN cave resolve -zx net-misc/openssh app-admin/sudo
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -A -t rsa -f /etc/ssh/ssh_host_rsa_key
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -A -t dsa -f /etc/ssh/ssh_host_dsa_key
          CODE
        end

        def opensuse_platform
          <<-CODE
            ENV container docker
            RUN zypper install -y sudo openssh which curl
            RUN /usr/sbin/sshd-gen-keys-start
          CODE
        end

        def rhel_platform
          <<-CODE
            ENV container docker
            RUN yum clean all
            RUN yum install -y sudo openssh-server openssh-clients which curl
            RUN [ -f "/etc/ssh/ssh_host_rsa_key" ] || ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
            RUN [ -f "/etc/ssh/ssh_host_dsa_key" ] || ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''
          CODE
        end

        def dockerfile_base_linux(username, homedir)
          <<-CODE
            RUN if ! getent passwd #{username}; then \
                  useradd -d #{homedir} -m -s /bin/bash -p '*' #{username}; \
                fi
            RUN echo "#{username} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/#{username}
            RUN echo "Defaults !requiretty" >> /etc/sudoers.d/#{username}
            RUN mkdir -p #{homedir}/.ssh
            RUN chown -R #{username} #{homedir}/.ssh
            RUN chmod 0700 #{homedir}/.ssh
            RUN touch #{homedir}/.ssh/authorized_keys
            RUN chown #{username} #{homedir}/.ssh/authorized_keys
            RUN chmod 0600 #{homedir}/.ssh/authorized_keys
            RUN mkdir -p /run/sshd
          CODE
        end
      end
    end
  end
end
