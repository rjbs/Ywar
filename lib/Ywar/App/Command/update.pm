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
use Ywar::Maildir -all;
use WebService::RTMAgent;

use Ywar::Config;

sub opt_spec {
  return (
    [ 'debug|d'   => 'debugging output' ],
    [ 'dry-run|n' => 'dry run!' ],
  );
}

my $dsn = Ywar::Config->config->{Ywar}{dsn};
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

sub max { (sort { $b <=> $a } @_)[0] }

my $ROOT = Ywar::Config->config->{Maildir}{root};

our $OPT;

use String::Flogger 'flog';
sub debug { return unless $OPT->debug; STDERR->say(flog($_)) for @_ }

sub _do_check {
  my ($self, $id, $name, $class, $check, $extra) = @_;

  warn("no existing measurements for $name\n"), return
    unless my $prev = most_recent_measurement($name);

  $class = "Ywar::Observer::$class";
  state %obs;
  $obs{$class} ||= do { load_class($class); $class->new; };

  my $new = $obs{$class}->$check($prev, @{ $extra // [] });

  debug("$name = no measurement"), return unless $new;
  debug("$name", $prev, $new);
  complete_goal($id, $new->{note}, $prev) if $new->{met_goal};
  save_measurement("$name", $new->{value}, $prev);
}

sub execute {
  my ($self, $opt, $args) = @_;
  local $OPT = $opt; # XXX <- temporary hack

  # 334 - write a journal entry
  JOURNAL: {
    $self->_do_check(334, 'journal.any', 'Rubric', 'posted_new_entry');
  }

  # flagged mail should be less than it was last time, or <10
  MAILDIR: {
    $self->_do_check(
      45660, 'mail.flagged',
      'Maildir', 'decreasing_flagged_mail'
    );
  }

  {
    $self->_do_check(
      333, 'mail.unread',
      'Maildir', 'decreasing_unread_mail'
    );

    # 325 - review perl.git commits
    $self->_do_check(
      325, 'p5p.changes',
      'Maildir', 'folder_old_unread',
      [ { age => 3*86_400, folder => '/INBOX/perl/changes' } ],
    );

    # 328 - get p5p unread count for mail >2wk old
    # should be 0 or descending
    $self->_do_check(
      328, 'p5p.unread',
      'Maildir', 'folder_old_unread',
      [ { age => 14*86_400, folder => '/INBOX/perl/p5p' } ],
    );
  }

  {
    $self->_do_check(
      37751, 'p5p.perlball',
      'GitHub', 'branch_sha_changed',
      [ rjbs => perlball => 'master' ],
    );

    $self->_do_check(
      335, 'tickets',
      'GitHub', 'file_sha_changed',
      [ rjbs => misc => 'code-review.mkdn' ],
    );

    $self->_do_check(49957, 'github.issues', 'GitHub', 'closed_issues');
  }

  # 49985 - step on the scale
  SCALE: {
    $self->_do_check(49985, 'weight.measured', 'Withings', 'measured_weight');
  }

  # 37752 - write an opening sentence
  OPENER: {
    $self->_do_check(
      37752, 'writing.openers',
      'Filesystem', 'more_files_in_dir',
      [ '/home/rjbs/Dropbox/writing/openers' ],
    );
  }

  {
    $self->_do_check(47355, 'rtm.overdue', 'RTM', 'nothing_overdue');
    $self->_do_check(47730, 'rtm.progress', 'RTM', 'closed_old_tasks');
  }

  INSTAPROGRESS: {
    $self->_do_check(49692, 'instapaper.progress', 'Instapaper', 'did_reading');
  }
}

sub complete_goal {
  my ($id, $note, $prev) = @_;
  return unless dayold($prev);
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
  return unless dayold($prev);
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
