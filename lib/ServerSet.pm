package ServerSet;
use strict;
use warnings;
use Path::Tiny ();
use File::Temp qw(tempdir);
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use AnyEvent;
use AbortController;
use Promise;
use Promised::Flow;
use Promised::File;
use Promised::Command;
use Promised::Command::Signals;
use JSON::PS;
use Web::Host;
use Web::URL;
use Web::Transport::BasicClient;
use Web::Transport::FindPort;

my $DEBUG = $ENV{SS_DEBUG};
my $DEBUG_SERVERS = {map { $_ => 1 } split /,/, $ENV{SS_DEBUG_SERVERS} // ''};

sub wait_for_http ($$%) {
  my (undef, $url, %args) = @_;
  my $client = Web::Transport::BasicClient->new_from_url ($url, {
    last_resort_timeout => 1,
  });
  my $checker = $args{check} || sub { 1 };
  return promised_cleanup {
    return $client->close;
  } promised_wait_until {
    return Promise->resolve->then ($checker)->then (sub {
      die "|check| failed" unless $_[0];
      return (promised_timeout {
        return $client->request (url => $url)->then (sub {
          return 0 if $_[0]->is_network_error;
          ## minio can return 503 before it becomes ready.
          return 0 if $_[0]->status == 503;
          return 1;
        });
      } 1);
    })->catch (sub {
      $client->abort;
      $client = Web::Transport::BasicClient->new_from_url ($url);
      return 0;
    });
  } timeout => 60, interval => 0.3, signal => $args{signal}, name => $args{name};
} # wait_for_http

sub dsn ($$$) {
  my (undef, $type, $v) = @_;
  return 'dbi:'.$type.':' . join ';', map {
    if (UNIVERSAL::isa ($v->{$_}, 'Web::Host')) {
      $_ . '=' . $v->{$_}->to_ascii;
    } else {
      $_ . '=' . $v->{$_};
    }
  } keys %$v;
} # dsn

sub path ($$) {
  return $_[0]->{data_root_path}->child ($_[1]);
} # path

sub artifacts_path ($$) {
  my $self = $_[0];
  $self->{artifacts_path} //= defined $ENV{CIRCLE_ARTIFACTS}
      ? Path::Tiny::path ($ENV{CIRCLE_ARTIFACTS})
      : $self->path ('artifacts');
  return defined $_[1] ? $self->{artifacts_path}->child ($_[1]) : $self->{artifacts_path};
} # artifacts_path

sub write_file ($$$) {
  my $self = $_[0];
  my $path = $self->path ($_[1]);
  my $file = Promised::File->new_from_path ($path);
  return $file->write_byte_string ($_[2]);
} # write_file

sub write_json ($$$) {
  my $self = $_[0];
  return $self->write_file ($_[1], perl2json_bytes $_[2]);
} # write_json

sub read_json ($$) {
  my $self = $_[0];
  my $path = ref $_[1] eq 'REF' ? ${$_[1]} : $self->path ($_[1]);
  my $file = Promised::File->new_from_path ($path);
  return $file->is_file->then (sub {
    if ($_[0]) {
      return $file->read_byte_string->then (sub {
        return json_bytes2perl $_[0];
      });
    } else {
      return {};
    }
  });
} # read_json

sub _add_key_defs ($$) {
  my ($self, $keys) = @_;
  for (keys %$keys) {
    if (defined $self->{key_defs}->{$_}) {
      die "Duplicate key |$_|";
    }
    $self->{key_defs}->{$_} = $keys->{$_};
  }
} # _add_key_defs

{
  my @KeyChar = ('0'..'9', 'A'..'Z', 'a'..'z', '_');
  sub _random_string ($) {
    my $n = shift;
    my $key = '';
    $key .= $KeyChar[rand @KeyChar] for 1..$n;
    return $key;
  } # _random_string
}

sub _generate_keys ($) {
  my ($self) = @_;
  return Promise->resolve->then (sub {
    return $self->read_json ('keys.json');
  })->then (sub {
    $self->{keys} = $_[0];
    for my $name (keys %{$self->{key_defs}}) {
      next if defined $self->{keys}->{$name};
      my $type = $self->{key_defs}->{$name} // '';
      if ($type eq 'id') {
        $self->{keys}->{$name} = int rand 1000000000;
      } elsif ($type eq 'key') {
        $self->{keys}->{$name} = _random_string (30);
      } elsif ($type =~ m{\Akey:,([0-9]+)\z}) {
        $self->{keys}->{$name} = _random_string (0+$1);
      } elsif ($type eq 'text') {
        $self->{keys}->{$name} = _random_string (30); # XXX
      } elsif ($type eq 'email') {
        $self->{keys}->{$name} = _random_string (30) . '@' . _random_string (10) . '.test';
      } else {
        die "Unknown key type |$type|";
      }
    }
  })->then (sub {
    return $self->write_json ('keys.json', $self->{keys});
  });
} # _generate_keys

sub key ($$) {
  my ($self, $name) = @_;
  return $self->{keys}->{$name} // die "Key |$name| not defined";
} # key

sub set_hostport ($$$$) {
  my ($self, $name, $host, $port) = @_;
  die "Can't set |$name| hostport anymore"
      if defined $self->{servers}->{$name};
  $self->_register_server ($name, $host, $port);
} # set_hostport

sub _register_server ($$;$$) {
  my ($self, $name, $host, $port) = @_;
  $self->{servers}->{$name} ||= do {
    $port //= find_listenable_port;
    #$host //= Web::Host->parse_string ('127.0.0.1');
    $host //= Web::Host->parse_string ('0'); # need to bind all for container->port accesses
    my $local_url = Web::URL->parse_string
        ("http://".$host->to_ascii.":$port");

    my $data = {local_url => $local_url};

    if ($name eq 'proxy') {
      require ServerSet::DockerHandler;
      my $docker_url = Web::URL->parse_string ("http://".ServerSet::DockerHandler->dockerhost->to_ascii.":$port");
      $data->{local_envs} = {
        http_proxy => $local_url->get_origin->to_ascii,
      };
      $data->{docker_envs} = {
        http_proxy => $docker_url->get_origin->to_ascii,
      };
    } else {
      my $client_url = Web::URL->parse_string ("http://$name.server.test");
      $data->{client_url} = $client_url;
      $self->{proxy_map}->{"$name.server.test"} = $local_url;
    }
    
    $data;
  };
} # _register_server

sub client_url ($$) {
  my ($self, $name) = @_;
  $self->_register_server ($name);
  return $self->{servers}->{$name}->{client_url} // die "No |$name| client URL";
} # client_url

sub local_url ($$) {
  my ($self, $name) = @_;
  $self->_register_server ($name);
  return $self->{servers}->{$name}->{local_url};
} # local_url

sub set_local_envs ($$$) {
  my ($self, $name, $dest) = @_;
  $self->_register_server ($name);
  my $envs = $self->{servers}->{$name}->{local_envs} // die "No |$name| envs";
  $dest->{$_} = $envs->{$_} for keys %$envs;
} # set_local_envs

sub set_docker_envs ($$$) {
  my ($self, $name, $dest) = @_;
  $self->_register_server ($name);
  my $envs = $self->{servers}->{$name}->{docker_envs} // die "No |$name| envs";
  $dest->{$_} = $envs->{$_} for keys %$envs;
} # set_docker_envs

sub run ($$$%) {
  my ($class, $server_defs, $prep_params, %args) = @_;

  if (length ($ENV{SS_ENV_FILE} // '')) {
    return Promised::File->new_from_path (Path::Tiny::path ($ENV{SS_ENV_FILE}))->read_byte_string->then (sub {
      die $args{signal}->manakai_error if $args{signal}->aborted;
      no strict;
      my $data = eval $_[0];
      die "$ENV{SS_ENV_FILE}: $@" if $@;
      my ($r, $s) = promised_cv;
      $args{signal}->manakai_onabort ($s);
      return {data => $data, done => $r};
    });
  }

  my $self = bless {
    proxy_map => {},
    data_root_path => $args{data_root_path},
    keys => {},
    key_defs => {},
  }, $class;
  my $need_cleanup = 0;
  unless (defined $args{data_root_path}) {
    my $tempdir = tempdir (CLEANUP => 1);
    $self->{data_root_path} = Path::Tiny::path ($tempdir);
    $self->{_tempdir} = $tempdir;
    $need_cleanup = 1;
  }
  my $cleanup = sub {
    return unless $need_cleanup;
    my $cmd = Promised::Command->new ([
      'docker',
      'run',
      '-v', $self->{data_root_path}->absolute . ':/data',
      'quay.io/wakaba/docker-perl-app-base',
      'chown', '-R', $<, '/data',
    ]);
    return $cmd->run->then (sub { return $cmd->wait });
  }; # $cleanup

  return Promise->resolve->then (sub {
    return $prep_params->($self, \%args);
  })->then (sub {
    my $prepared = $_[0];
    
    $self->set_hostport ($_, @{$prepared->{exposed}->{$_}})
        for keys %{$prepared->{exposed}};

    my $servers = $prepared->{server_params};

    my $handlers = {};
    my $acs = {};
    my $data_send = {};
    my $data_receive = {};
    {
      ($data_receive->{_}, $data_send->{_}) = promised_cv;
      $data_send->{_}->({})
          if not defined $servers->{_} or $servers->{_}->{disabled};
    }
    for my $name (keys %$servers) {
      next if $servers->{$name}->{disabled};

      my $def = $server_defs->{$name} or die "Server |$name| not defined";
      my $class = $def->{handler} // 'ServerSet::DefaultHandler';
      eval qq{ require $class } or die $@;
      $handlers->{$name} = $class->new_from_params ($def);

      $acs->{$name} = AbortController->new;
      $servers->{$name}->{signal} = $acs->{$name}->signal;
      for my $other (@{$def->{requires} or []}) {
        die "Bad server |$other|" unless defined $servers->{$other};
        unless (defined $data_send->{$other}) {
          ($data_receive->{$other}, $data_send->{$other}) = promised_cv;
          $data_send->{$other}->(undef) if $servers->{$other}->{disabled};
        }
        $servers->{$name}->{'receive_' . $other . '_data'} = $data_receive->{$other};
      }

      $self->_add_key_defs ($handlers->{$name}->get_keys);
    } # $servers

    my @started;
    my @done;
    my @signal;
    my $stopped;
    my $stop = sub {
      my $cancel = $_[0] || sub { };
      $cancel->();
      $stopped = 1;
      @signal = ();
      $_->abort for values %$acs;
    }; # $stop
    
    $args{signal}->manakai_onabort (sub { $stop->(undef) })
        if defined $args{signal};
    push @signal, Promised::Command::Signals->add_handler (INT => $stop);
    push @signal, Promised::Command::Signals->add_handler (TERM => $stop);
    push @signal, Promised::Command::Signals->add_handler (KILL => $stop);
    
    my $gen = $self->_generate_keys;

    my $error;
    my $waitings = {};
    my $some_failed = 0;
    for my $name (keys %$handlers) {
      my $started = $gen->then (sub {
        warn "$$: SS: |$name|: Start...\n" if $DEBUG;
        $waitings->{$name} = 'starting';
        $handlers->{$name}->onstatechange (sub { $waitings->{$name} = $_[1] });
        return promised_timeout {
          return $handlers->{$name}->start (
            $self,
            %{$servers->{$name}},
            debug => $DEBUG_SERVERS->{$name} || $DEBUG_SERVERS->{all},
          );
        } 60*5;
      })->then (sub {
        my ($data, $done) = @{$_[0]}; 
        warn "$$: SS: |$name|: Started\n" if $DEBUG;
        $data_send->{$name}->($data) if defined $data_send->{$name};
        push @done, $done;
        delete $waitings->{$name};
        if ($data->{failed}) {
          warn sprintf "========== Logs of |%s| ======\n%s\n====== /Logs of |%s| ======\n",
              $name,
              $handlers->{$name}->logs,
              $name;
        }
        return undef;
      })->catch (sub {
        $error //= $_[0];
        warn "$$: SS: |$name|: Failed to start ($error)\n" if $DEBUG;
        delete $waitings->{$name};
        unless ($some_failed) {
          warn sprintf "========== Logs of |%s| ======\n%s\n====== /Logs of |%s| ======\n",
              $name,
              $handlers->{$name}->logs,
              $name;
        }
        $some_failed = 1;
        $stop->(undef);
        $data_send->{$name}->(Promise->reject ($_[0]))
            if defined $data_send->{$name};
      });
      push @started, $started;
      push @done, $started;
    } # $name

    my $repeat = $DEBUG ? AE::timer 0, 10, sub {
      return unless keys %$waitings;
      warn "$$: SS: Waiting for ", (join ', ', map {
        sprintf '%s[%s]', $_, $waitings->{$_};
      } keys %$waitings), "...\n";
    } : undef;
    return Promise->all (\@started)->then (sub {
      die $error // "Stopped" if $stopped;
      return $data_receive->{_};
    })->then (sub {
      my $data = $_[0];
      undef $repeat;
      warn "$$: SS: Servers are ready\n" if $DEBUG;

      my $pid_file = $args{write_ss_env} ? Promised::File->new_from_path ($self->artifacts_path ('ss.pid')) : undef;
      return Promise->all ([
        ($args{write_ss_env} ? Promised::File->new_from_path ($self->artifacts_path ('ss.env'))->write_byte_string (Dumper $data) : undef),
        (defined $pid_file ? $pid_file->write_byte_string ($$) : undef),
      ])->then (sub {
        return {data => $data, done => Promise->all (\@done)->finally (sub {
          return $pid_file->remove_tree if defined $pid_file;
        })->finally (sub {
          return $cleanup->();
        })};
      })->catch (sub {
        my $e = $_[0];
        return $pid_file->remove_tree->finally (sub { die $e })
            if defined $pid_file;
        die $e;
      });
    })->catch (sub {
      my $e = $_[0];
      $stop->();
      return Promise->all (\@done)->finally (sub {
        return $cleanup->();
      })->finally (sub {
        die $e;
      });
    });
  });
} # run

1;

=head1 LICENSE

Copyright 2018-2020 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
