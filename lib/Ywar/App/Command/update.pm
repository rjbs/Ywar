use 5.16.0;
use warnings;
use utf8;
package Ywar::App::Command::update;
use Ywar::App -command;

use Class::Load qw(load_class);
use DateTime;
use DateTime::Duration;
use DateTime::Format::ISO8601;
use DBI;
use Getopt::Long::Descriptive;
use JSON ();
use List::AllUtils 'sum0';
use LWP::Authen::OAuth;
use LWP::UserAgent;
use LWP::Simple qw(get);
use Pithub;
use Net::OAuth::Client;
use Try::Tiny;
use Ywar::Maildir -all;
use WebService::RTMAgent;

use Ywar::Config;

sub opt_spec {
  return (
    [ 'debug|d'   => 'debugging output' ],
    [ 'dry-run|n' => 'dry run!' ],
  );
}

my $dsn = Ywar::Config->config->{dsn};
my $dbh = DBI->connect($dsn, undef, undef)
  or die $DBI::errstr;

sub most_recent_measurement {
  my ($thing) = @_;
  return $dbh->selectrow_hashref(
    "SELECT thing_measured, measured_at, measured_value
    FROM lifestats
    WHERE thing_measured = ?
    ORDER BY measured_at DESC",
    undef,
    $thing,
  );
}

sub dayold {
  my ($measurement) = @_;
  return 1 if $^T - $measurement->{measured_at} >= 86_000; # 400s grace
  return;
}

our $OPT;

use String::Flogger 'flog';
sub debug { return unless $OPT->debug; STDERR->say(flog($_)) for @_ }

sub _do_check {
  my ($self, $id, $name, $obs, $check, $extra) = @_;

  warn("no existing measurements for $name\n"), return
    unless my $prev = most_recent_measurement($name);

  my $new;

  try {
    $new = $obs->$check($prev, $extra // {});
  } catch {
    warn "error while checking $name: $_";
  };

  debug("$name = no measurement"), return unless $new;
  debug([ "$name = %s -> %s", $prev, $new ]);
  debug("$name = too recent; not saving"), return unless dayold($prev);
  complete_goal($id, $new->{note}, $prev) if $new->{met_goal};
  save_measurement("$name", $new->{value}, $prev);
}

sub execute {
  my ($self, $opt, $args) = @_;
  local $OPT = $opt; # XXX <- temporary hack

  # TODO: turn config into plan first, so we can detect duplicates and barf
  # before doing anything stupid -- rjbs, 2013-11-02
  my $observers = Ywar::Config->config->{observers};
  for my $plugin_name (sort keys %$observers) {
    my $hunk    = $observers->{ $plugin_name };
    my $moniker = $hunk->{class} // $plugin_name; # do RewritePrefix
    my $config  = $hunk->{config};

    my $class = "Ywar::Observer::$moniker";
    my $obs   = do { load_class($class); $class->new($config // {}); };

    for my $check_name (keys %{$hunk->{checks}}) {
      my $check = $hunk->{checks}{$check_name};

      $self->_do_check(
        $check->{'tdp-id'}, $check_name,
        $obs, $check->{method},
        $check->{args},
      );
    }
  }
}

sub complete_goal {
  my ($id, $note, $prev) = @_;
  if ($OPT->dry_run) {
    warn "dry run: not completing goal $id ($note)\n";
    return;
  }

  my $res = LWP::UserAgent->new->post(
    "http://tdp.me/v1/goals/$id/completion",
    Content => JSON->new->encode({ note => $note }),
    'Content-type' => 'application/json',
    'X-Access-Token' => Ywar::Config->config->{TDP}{token},
  );

  warn "error completing $id: " . $res->status unless $res->is_success;
}

sub save_measurement {
  my ($thing, $value, $prev) = @_;
  if ($OPT->dry_run) {
    warn "dry run: not really setting $thing to $value\n";
    return;
  }

  return $dbh->selectrow_hashref(
    "INSERT INTO lifestats (thing_measured, measured_at, measured_value)
    VALUES (?, ?, ?)",
    undef,
    $thing, $^T, $value,
  );
}

1;
