use 5.14.0;
package Ywar::Observer::Goodreads;
use Moose;

use LWP::UserAgent;
use XML::Tiny;
use JSON 'decode_json', 'encode_json';
use DateTime::Format::ISO8601;

has api_key => (
   is => 'ro',
   required => 1,
);

has user_id => (
   is => 'ro',
   required => 1,
);

has _statuses => (
   is => 'ro',
   lazy => 1,
   builder => '_get_statuses',
);

sub _get_statuses {
  my $self = shift;

  my $ua = LWP::UserAgent->new(keep_alive => 1);

  my $response = $ua->get(
    sprintf 'https://www.goodreads.com/user/show/%d.xml?key=%s',
      $self->user_id, $self->api_key,
  );

  my $data = XMLin($response->decoded_content);

  $data->{user}{updates}{update};
}

sub did_read {
  my ($self, $prev, $args) = @_;

  warn "title match: $args->{match_title}";

  use Devel::Dwarn;
  my $now = DateTime->now->epoch;
  my @important_data =
  grep { $now - $_->{created_at}->epoch < 24 * 60 * 60 }
  map {
    my $us = $_->{object}{user_status};
    my $b = $us->{book};
    +{
      title => $b->{title},
      book_id => $us->{book_id}{content},
      created_at => DateTime::Format::ISO8601->parse_datetime($us->{created_at}{content}),
      current_page => $us->{page}{content},
      total_pages => $b->{num_pages}{content},
    }
  }
  grep $_->{object}{user_status}{book}->{title}->$Dwarn =~ m/$args->{match_title}/,
  grep $_->{action_text} =~ m/^is on page \d+ of \d+/,
  @{$self->_statuses};

  my %progress      = map { $_->{book_id} => $_ } @important_data;
  my %prev_progress = map { $_->{book_id} => $_ } @{decode_json($prev->{measured_value})};
  my %new_progress;

  for (keys %progress) {
      if (!exists $prev_progress{$_}) {
         $new_progress{$_} = $progress{$_};
      } elsif ($prev_progress{$_} < $progress{$_}) {
         $new_progress{$_} = [$progress{$_}, $prev_progress{$_}];
      } elsif ($progress{$_} < $prev_progress{$_}) {
         die "why are you reading backwards you dummy?\n"
      }
  }

  for (keys %prev_progress) {
      if (!exists $progress{$_}) {
         $new_progress{$_} = 'complete!'
      }
  }

  $progress{$_}{created_at} = "$progress{$_}{created_at}"
    for keys %progress;
  Ddie \%progress;
  return {
    note => ,
    value => encode_json(\%progress),
    met_goal => scalar %new_progress ? 1 : 0,
  };
}

1;

__END__

  Goodreads:
     config:
        api_key: foo
        user_id: baz
     checks:
         read.acm:
             method: did_read
             tdp-id: 123
             args:
                match_title: Communcations of the ACM
         read.imbibe:
             method: did_read
             tdp-id: 124
             args:
                match_title: Imbibe

