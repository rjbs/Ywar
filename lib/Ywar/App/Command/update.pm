use 5.16.0;
use warnings;
use utf8;
package Ywar::App::Command::update;
use Ywar::App -command;

use Class::Load qw(load_class);
use DateTime;
use DBI;
use Getopt::Long::Descriptive;
use JSON ();
use LWP::UserAgent;
use Try::Tiny;

use Ywar::Config;
use Ywar::LastState;

sub opt_spec {
  return (
    [ 'debug|d'   => 'debugging output' ],
    [ 'dry-run|n' => 'dry run!' ],
  );
}

my $dsn = Ywar::Config->config->{dsn};
my $dbh = DBI->connect($dsn, undef, undef)
  or die $DBI::errstr;

sub last_state_for {
  my ($thing) = @_;

  my $any = $dbh->selectrow_hashref(
    "SELECT thing_measured, measured_at, measured_value
    FROM lifestats
    WHERE thing_measured = ?
    ORDER BY measured_at DESC
    LIMIT 1",
    undef,
    $thing,
  );

  my $done = $dbh->selectrow_hashref(
    "SELECT thing_measured, measured_at, measured_value
    FROM lifestats
    WHERE thing_measured = ? AND goal_completed
    ORDER BY measured_at DESC
    LIMIT 1",
    undef,
    $thing,
  );

  my $today_start = DateTime->today(time_zone => Ywar::Config->time_zone);
  my $yest_start  = $today_start->clone->subtract(days => 1);

  my $yesterday_value = $dbh->selectrow_hashref(
    "SELECT thing_measured, measured_at, measured_value
    FROM lifestats
    WHERE thing_measured = ?
      AND CAST(measured_at AS INTEGER) >= CAST(? AS INTEGER)
      AND CAST(measured_at AS INTEGER) <  CAST(? AS INTEGER)
    ORDER BY measured_at DESC
    LIMIT 1",
    undef,
    $thing,
    $yest_start->epoch,
    $today_start->epoch,
  );

  return Ywar::LastState->new({
    ($any  ? (measurement => $any)  : ()),
    ($done ? (completion  => $done) : ()),
    ($yesterday_value ? (yesterday_value  => $yesterday_value) : ()),
  });
}

sub dayold {
  my ($measurement) = @_;
  return 1 if $^T - $measurement->{measured_at} >= 86_000; # 400s grace
  return;
}

sub _push_notif {
  my ($self, $text) = @_;

  my $observers = Ywar::Config->config->{observers};
  my $ua  = LWP::UserAgent->new;
  my $res = $ua->post(
    "https://api.pushover.net/1/messages.json",
    {
      user    => Ywar::Config->config->{Pushover}{usertoken},
      token   => Ywar::Config->config->{Pushover}{apptoken},
      message => "$text",
      title   => "Ywar: goal complete",
    },
  );

  unless ($res->is_success) {
    warn "error with push notification: " . $res->as_string;
  }
}

our $OPT;

use String::Flogger 'flog';
sub debug { return unless $OPT->debug; STDERR->say(flog($_)) for @_ }

sub _do_check {
  my ($self, $id, $name, $obs, $check, $extra) = @_;

  my $laststate = last_state_for($name);

  warn("no existing measurements for $name\n"), return
    unless $laststate->has_measurement
    and    $laststate->has_completion;

  my $new;

  try {
    $new = $obs->$check($laststate, $extra // {});
  } catch {
    warn "error while checking $name: $_";
  };

  debug("$name = no measurement"), return unless $new;
  debug([
    "$name = (M: %s / C: %s) -> %s",
    $laststate->measurement->{measured_value},
    $laststate->completion->{measured_value},
    $new,
  ]);

  # debug("$name = too recent; not saving"), return unless dayold($done);

  update_tdp($id, $new) if $new->{met_goal};
  $self->_push_notif("completed goal: $name") if $new->{met_goal};
  save_measurement("$name", $new);
}

sub execute {
  my ($self, $opt, $args) = @_;
  local $OPT = $opt; # XXX <- temporary hack

  my %to_check = map {; $_ => 1 } @$args;

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
      next if keys %to_check && ! $to_check{$check_name};

      my $check = $hunk->{checks}{$check_name};

      $self->_do_check(
        $check->{'tdp-id'}, $check_name,
        $obs, $check->{method},
        $check->{args},
      );
    }
  }
}

sub update_tdp {
  my ($id, $new) = @_;
  if ($OPT->dry_run) {
    warn "dry run: not completing goal $id ($new->{note})\n";
    return;
  }

  my $res = LWP::UserAgent->new->post(
    "https://tdp.me/v1/goals/$id/completion",
    Content => JSON->new->encode({
      note     => $new->{note},
      quantity => ($new->{met_goal} ? 1 : 0),
    }),
    'Content-type' => 'application/json',
    'X-Access-Token' => Ywar::Config->config->{TDP}{token},
  );

  warn "error updating goal $id: " . $res->as_string unless $res->is_success;
}

sub save_measurement {
  my ($thing, $new) = @_;
  if ($OPT->dry_run) {
    warn "dry run: not really setting $thing to $new->{value}\n";
    return;
  }

  return $dbh->selectrow_hashref(
    "INSERT INTO lifestats
      (thing_measured, measured_at, measured_value, goal_completed)
    VALUES (?, 0+?, ?, 0+?)",
    undef,
    $thing, $^T, $new->{value}, ($new->{met_goal} ? 1 : 0),
  );
}

1;
