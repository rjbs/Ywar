use strict;
use warnings;
package Ywar::Logger;
use parent 'Log::Dispatchouli::Global';

use Log::Dispatchouli 2.002;
use Ywar::Config;

sub logger_globref {
  no warnings 'once';
  \*Logger;
}

sub default_logger_class { 'Ywar::Logger::_Logger' }

sub default_logger_args {
  return {
    ident     => "Ywar",
    facility  => undef,
    log_pid   => 0,
    # to_stderr => $_[0]->default_logger_class->env_value('STDERR') ? 1 : 0,

    ( Ywar::Config->config->{log_dir}
      ? (log_path => Ywar::Config->config->{log_dir},
         to_file  => 1)
      : ()
    ),
  }
}

{
  package Ywar::Logger::_Logger;
  use parent 'Log::Dispatchouli';

  sub env_prefix { 'YWAR_LOG' }
}

1;
