use 5.14.0;
package Ywar::Observer::Filesystem;
use Moose;

use Path::Iterator::Rule;
use Ywar::Util qw(not_today);

sub more_files_in_dir {
  my ($self, $laststate, $arg) = @_;
  my $dir = $arg->{dir};

  my $count = Path::Iterator::Rule->new->file->all($dir);

  my $last = $laststate->completion->{measured_value};
  warn "fewer files today ($count) than last time ($last)\n"
    if $count < $last;

  return {
    value    => $count,
    met_goal => $count > $last && not_today($laststate->completion),
    note     => "files added: " . ($count - $last),
  };
}

# not sure I'm happy with this being a distinct method
sub more_files_across_dirs {
  my ($self, $laststate, $arg) = @_;
  my $dirs = $arg->{dirs};

  my $count = Path::Iterator::Rule->new->file->all(@$dirs);

  my $last = $laststate->completion->{measured_value};
  warn "fewer files today ($count) than last time ($last)\n"
    if $count < $last;

  return {
    value    => $count,
    met_goal => $count > $last && not_today($laststate->completion),
    note     => "files added: " . ($count - $last),
  };
}

sub fewer_files_in_dir {
  my ($self, $laststate, $arg) = @_;
  my $dir = $arg->{dir};

  my $count = Path::Iterator::Rule->new->file->all($dir);

  my $last = $laststate->completion->{measured_value};

  return {
    value    => $count,
    met_goal => $count < $last && not_today($laststate->completion),
    note     => "files cleared: " . ($last - $count),
  };
}

1;
