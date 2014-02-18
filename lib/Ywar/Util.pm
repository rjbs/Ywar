use 5.14.0;
use warnings;
package Ywar::Util;

use Sub::Exporter -setup => [ qw(not_today) ];

sub not_today {
  my $epoch = $_[0]->{measured_at};
  my $dt    = DateTime->from_epoch(
    epoch => $epoch,
    time_zone => Ywar::Config->time_zone,
  )->truncate(to => 'day');

  return $dt != DateTime->today(time_zone => Ywar::Config->time_zone);
}

1;
