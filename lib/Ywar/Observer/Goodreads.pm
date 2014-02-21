use 5.16.0;
package Ywar::Observer::Goodreads;
use Moose;

use JSON 2 ();
use LWP::UserAgent;
use List::AllUtils 'uniq';
use XML::LibXML;

has api_key => (
  is => 'ro',
  required => 1,
);

has user_id => (
  is => 'ro',
  required => 1,
);

has lwp => (
  is => 'ro',
  default => sub { LWP::UserAgent->new(keep_alive => 2) },
);

my $BASE = 'https://www.goodreads.com';

my $JSON = JSON->new;

sub read_pages_on_shelf {
  my ($self, $laststate, $arg) = @_;

  unless ($arg->{goal_pages}) { warn "no goal pages set!"; return; }
  unless ($arg->{shelf})      { warn "no shelf selected!"; return; }

  my $old  = $JSON->decode( $laststate->completion->{measured_value} );

  my $res = LWP::UserAgent->new->get(
    sprintf 'https://www.goodreads.com/review/list?format=json&v=2&id=%s&key=%s&shelf=currently-reading',
      $self->user_id,
      $self->api_key,
  );

  my @review_ids = uniq(
    (map {; $_->{id} } @{ $JSON->decode($res->decoded_content) }),
    keys %$old,
  );

  my %current;
  REVIEW: for my $review_id (@review_ids) {
    my $status = $self->_get_review_status($review_id);
    next REVIEW unless grep {; fc $_ eq fc $arg->{shelf} } @{$status->{shelves}};
    $current{ $review_id } = $status;
  }

  my %to_save;
  my $total_diff;
  my @notes;
  for my $id (keys %current) {
    my $status = $current{$id};
    my $diff   = $status->{current_page} - ($old->{$id} // 0);
    $diff = 0 if $diff < 0;
    $total_diff += $diff;
    push @notes, "read $diff pages in $status->{title}" if $diff;
    $to_save{$id} = $status->{current_page}
      if grep { fc $_ eq 'currently-reading' } @{ $status->{shelves} };
  }

  return {
    note  => join(q{; }, @notes),
    value => $JSON->encode(\%to_save),
    met_goal => $total_diff >= $arg->{goal_pages},
  };
}

sub _get_review_status {
  my ($self, $review_id) = @_;

  my %status;

  my $res = LWP::UserAgent->new->get(
    sprintf 'https://www.goodreads.com/review/show.xml?key=%s&id=%s',
      $self->api_key,
      $review_id,
  );

  open my $fh, '<', \$res->decoded_content(charset => 'none')
    or die "error making handle to XML results: $!";

  my $doc = XML::LibXML->load_xml(IO => $fh);

  $status{shelves} = [
    map {; $_->getAttribute('name') } $doc->getElementsByTagName('shelf')
  ];

  my $title = ($doc->getElementsByTagName('title'))[0]->textContent;

  my ($total_page_node) = $doc->getElementsByTagName('num_pages');
  my $page_count;
  unless ($total_page_node and ($page_count = $total_page_node->textContent)) {
    warn "couldn't figure out page count for book on review $review_id";
    next REVIEW;
  }

  $status{page_count} = $page_count;

  my ($latest) = $doc->getElementsByTagName('user_status');

  my $page = 0;
  if ($latest) {
    my ($page_node) = $latest->getElementsByTagName('page');
    my ($pct_node)  = $latest->getElementsByTagName('percent');

    $page = int(($page_node->getAttribute('nil') // 'false') eq 'false'
              ? $page_node->textContent
              : ($page_count * ($pct_node->textContent / 100)));
  }

  if (grep {; 'read' eq $_ } @{ $status{shelves} }) {
    $page = $page_count;
  }

  $status{current_page} = $page;
  $status{title} = $title;

  return \%status;
}

__END__

  Goodreads:
     config:
        api_key: foo
        user_id: baz
     checks:
       read.tech:
           method: read_pages_on_shelf
           tdp-id: 123
           args:
              shelf: tech
              goal_pages: 25
       read.literature:
           method: read_pages_on_shelf
           tdp-id: 124
           args:
              shelf: lit
              goal_pages: 50

