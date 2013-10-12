use 5.16.0;
use warnings;
package Ywar::Config;

use Carp qw(confess);
use Config::INI::Reader;

sub config {
  my ($self) = @_;

  state $config = do {
    confess "no YWAR_CONFIG_FILE" unless my $fn = $ENV{YWAR_CONFIG_FILE};
    Config::INI::Reader->read_file($fn);
  };

  return $config;
}

1;
