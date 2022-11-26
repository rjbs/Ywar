use 5.34.0;
use warnings;
use utf8;

package Ywar::App::Command::agenda;
use Ywar::App -command;

use DBI;
use Date::Parse;
use DateTimeX::Easy;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Getopt::Long::Descriptive;
use HTML::Entities;
use JSON::XS ();
use Lingua::EN::Inflect qw(NUMWORDS PL_N);
use LWP::UserAgent;
use POSIX qw(ceil);
use WebService::RTMAgent;
use YAML::XS ();
use Ywar::Config;

sub dt {
  DateTimeX::Easy->parse(@_)
    ->set_time_zone(Ywar::Config->time_zone)
    ->truncate(to => 'day')
}

sub _rtm_ua {
  my ($self) = @_;
  $self->{_rtm_ua} ||= do {
    my $rtm_ua = WebService::RTMAgent->new;
    my $config = Ywar::Config->config->{observers}{RTM}{config};
    $rtm_ua->api_key( $config->{api_key} );
    $rtm_ua->api_secret( $config->{api_secret} );
    $rtm_ua->init;
    $rtm_ua;
  }
}

my $CSS = <<'END';
<style>
div.header {
  border: 1px black solid;
  padding: 0.25em 1em;
  background-color: #ffd;
  border-radius: 10px;
  text-align: center;
}

h2, h3 {
  border-bottom: thin black solid;
}
</style>
END

sub execute {
  my ($self, $opt, $args) = @_;

  my $today   = DateTime->today(time_zone => Ywar::Config->time_zone);
  my %for_date;

  {
    # GET RTM TASKS THAT HAVE DUE DATES
    my $rtm_res = $self->_rtm_ua->tasks_getList(
      'filter=status:incomplete AND (dueBefore:today OR dueWithin:"1 month")'
    );

    unless ($rtm_res) {
      die "RTM API error: " . $self->_rtm_ua->error;
    }

    my @series = @{ $rtm_res->{tasks}[0]{list} || [] };
    my @tasks  = map {; @{ $_->{taskseries} } } @series;

    for my $task (@tasks) {
      my $due = dt($task->{task}[0]{due}, tz => 'UTC');

      my $due_ymd = $due->ymd;

      my $overdue = $today > $due;
      my $overdue_by = $today->delta_days($due)->days;
      push @{ $for_date{ ($overdue ? $today : $due)->ymd } }, {
        name => $task->{name},
        ($overdue ? (overdue => $overdue_by) : ()),
      };
    }
  }

  {
    # PUT IN EXPIRY DATES FOR NEXT MONTH OF TDP TASKS
    my $MAX = '96';

    my $res = LWP::UserAgent->new->get(
      "http://tdp.me/v1/goals/?range=$MAX,7",
      'Content-type' => 'application/json',
      'X-Access-Token' => Ywar::Config->config->{TDP}{token},
    );

    my $json = $res->decoded_content;
    my $data = JSON::XS->new->decode($json);

    my @dead;
    my @confused;
    my $today_idx;

    for my $goal (sort { $a->{name} cmp $b->{name} } @{ $data->{goals} }) {
      next unless $goal->{active};
      next if grep {; $_->{name} eq 'noagenda' } @{ $goal->{tags} };

      unless ($today_idx) {
        ($today_idx) = grep { $goal->{trend}[$_]{today} }
                       (0 .. $#{ $goal->{trend} });
      }

      my $streak = $goal->{trend}[ $today_idx - 1 ]{streak};

      if ($streak) {
        my @actual_days = grep { defined $_->{id} } @{ $goal->{trend} || [] };
        if ( @actual_days ) {
          my $day  = DateTimeX::Easy->parse($actual_days[-1]->{date});
          my $date = $day->add( days => $goal->{cooldown})
                         ->format_cldr('yyyy-MM-dd');

          my $info = {
            name   => $goal->{name},
            streak => $streak,
          };

          push @{ $for_date{ $date } }, $info;
        } else {
          push @{ $for_date{ $today->ymd } }, {
            name   => $goal->{name},
            streak => $streak,
            status => "¿¿¿ streak>0 but end date unknown ???",
          };
        }
      } else {
        push @{ $for_date{ $today->ymd } }, {
          name   => $goal->{name},
          streak => "none",
        };
      }
    }
  }

  my $body = q{};
  for my $date (sort keys %for_date) {
    my $dt   = dt($date);
    my $days = ceil($dt->subtract_datetime_absolute($today)->seconds / 86400);

    if ($days == 0) {
      $body .= sprintf "<h2>Today!</h2>\n";
    } elsif ($days < 6) {
      $body .= sprintf "<h3>%s (%s)</h3>\n",
        $dt->format_cldr('cccc'),
        $dt->format_cldr('MMM d');
    } else {
      $body .= sprintf "<h3>In %s days, %s</h3>\n",
        $days > 12 ? $days : NUMWORDS($days),
        $dt->format_cldr('MMM d');
    }

    for my $item (
      sort { ($b->{overdue} // 0) <=> ($a->{overdue} // 0)
          ||  fc $a->{name}       cmp  fc $b->{name} }
      @{ $for_date{$date} }
    ) {
      my $text = encode_entities(delete $item->{name});
      if (my $streak = delete $item->{streak}) {
        $text .= " (streak: $streak)";
      }
      if (my $days_overdue = delete $item->{overdue}) {
        $text .= " (overdue by $days_overdue " . PL_N(day => $days_overdue) . ")";
      }
      $body .= "<li>$text</li>\n";

      for my $key (sort keys %$item) {
        warn sprintf "WEIRD: %s = %s\n", $key, $item->{$key};
      }
    }
  }

  my $prelude = sprintf '<div class="header">%s</div>',
    $today->format_cldr('cccc, MMMM dd, YYYY');

  my $email = Email::MIME->create(
    header_str => [
      Subject => "Ywar: daily agenda for " . $today->ymd,
      From    => Ywar::Config->config->{agenda}{hdr_from},
      To      => Ywar::Config->config->{agenda}{hdr_to},
    ],
    attributes => {
      content_type => 'text/html',
      encoding     => 'quoted-printable',
      charset      => 'utf-8',
    },
    body_str   => "$CSS\n$prelude\n$body\n",
  );

  # print $email->as_string;
  sendmail($email);
}

1;
