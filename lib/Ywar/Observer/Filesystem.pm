use 5.14.0;
package Ywar::Observer::Filesystem;
use Moose;

sub more_files_in_dir {
  my ($self, $prev, $dir) = @_;

  my $count = grep {; -f $_ } <$dir/*>;

  my $last = $prev->{measured_value};
  warn "fewer openers today ($count) than last time ($last)\n"
    if $count < $last;

  return {
    value    => $count,
    met_goal => $count > $last ? 1 : 0,
    note     => "files added: " . ($count - $last),
  };
}

1;
