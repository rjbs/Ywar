use 5.16.0;
use warnings;
package Ywar::Config;

use Carp qw(confess);
use YAML::XS 'LoadFile';

sub config {
  my ($self) = @_;

  state $config = do {
    my $fn = $ENV{YWAR_CONFIG_FILE} || "$ENV{HOME}/.ywar.yml";
    LoadFile($fn);
  };

  return $config;
}

1;
