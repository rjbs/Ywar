use 5.14.0;
package Ywar::Observer::Instapaper;
use Moose;

use Ywar::Instapaper;

sub did_reading {
  my ($self, $prev) = @_;

  # Recorded is the number of items that were 14 days old yesterday.  The
  # number of items 15 days old today should be fewer.
  my %count;

  my @bookmarks = Ywar::Instapaper->bookmark_list;

  my $old_14 = grep { $_->{time} < $^T - 14 * 86_400 } @bookmarks;
  my $old_15 = grep { $_->{time} < $^T - 15 * 86_400 } @bookmarks;

  my $last = $prev->{measured_value};

  my %result;

  if ($old_15 < $last) {
    my $closed = $last - $old_15;
    @result{ qw(note met_goal) } = ("items read (or deleted): $closed", 1);
  }

  $result{value} = $old_14;

  return \%result;
}

1;
