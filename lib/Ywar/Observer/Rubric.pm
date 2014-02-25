use 5.14.0;
package Ywar::Observer::Rubric;
use Moose;

sub posted_new_entry {
  my ($self, $laststate) = @_;

  my $rubric_dbh = DBI->connect("dbi:SQLite:/home/rjbs/rubric/rubric.db", undef, undef)
    or die $DBI::errstr;

  my $last_post = $rubric_dbh->selectrow_hashref(
    "SELECT title, created
    FROM entries e
    JOIN entrytags et ON e.id = et.entry
    WHERE body IS NOT NULL AND LENGTH(body) > 0 AND tag='journal'
    ORDER BY e.created DESC
    LIMIT 1",
  );

  return { met_goal => 0, value => $laststate->measurement->{measured_value} }
    unless $last_post && $last_post->{created} > $laststate->measurement->{measured_value};

  return {
    met_goal => 1,
    note     => "lastest post: $last_post->{title}",
    value    => $last_post->{created},
  };
}

1;
