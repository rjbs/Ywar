use 5.16.0;
package Ywar::Observer::Goodreads;
use Moose;

use JSON 2 ();
use LWP::UserAgent;
use List::AllUtils 'uniq';
use XML::LibXML;
use Ywar::Logger '$Logger';

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

my $JSON = JSON->new->canonical;

sub read_pages_on_shelf {
  my ($self, $laststate, $arg) = @_;

  unless ($arg->{goal_pages}) { warn "no goal pages set!"; return; }
  unless ($arg->{shelf} or ($arg->{not_shelves} && @{$arg->{not_shelves}})) {
    warn "no shelf or not_shelves argument provided!";
    return;
  }

  my $old  = $JSON->decode( $laststate->completion->{measured_value} );

  my $res = LWP::UserAgent->new->get(
    sprintf 'https://www.goodreads.com/review/list?format=xml&v=2&id=%s&key=%s&shelf=currently-reading',
      $self->user_id,
      $self->api_key,
  );

  open my $fh, '<', \$res->decoded_content(charset => 'none')
    or die "error making handle to XML results: $!";

  my $doc = XML::LibXML->load_xml(IO => $fh);

  my @reviews = $doc->getElementsByTagName('review');
  my @review_ids = keys %$old;
  REVIEW: for my $review (@reviews) {
    my @shelves = map {; $_->getAttribute('name') }
                  $review->getElementsByTagName('shelf');

    next if $arg->{shelf} && ! grep {; fc $_ eq fc $arg->{shelf} } @shelves;
    for my $exclude (map {; fc } @{ $arg->{not_shelves} || [] }) {
      next REVIEW if grep {; fc $_ eq $exclude } @shelves;
    }

    my ($id_node) = $review->nonBlankChildNodes;
    die "first child in a <review> node was not its id: $review\n"
      unless $id_node->localname eq 'id';

    push @review_ids, $id_node->textContent;
  }

  my %current;
  REVIEW: for my $review_id (uniq @review_ids) {
    if (my $status = $self->_get_review_status($review_id)) {
      $current{ $review_id } = $status;
    } else {
      warn "couldn't deal with status of book $review_id";
    }
  }

  my $selector = '';
  $selector .= "on $arg->{shelf}"                if $arg->{shelf};
  $selector .= "not on (@{$arg->{not_shelves}})" if @{$arg->{not_shelves}||[]};

  my %to_save;
  my $total_diff = 0;
  my @notes;
  for my $id (keys %current) {
    my $status = $current{$id};
    my $diff   = $status->{current_page} - ($old->{$id} // 0);
    $diff = 0 if $diff < 0;
    $Logger->log([
      "%s, book %s, was on page %s, now on page %s",
      $selector,
      $status->{title},
      $old->{$id},
      $status->{current_page},
    ]);
    $total_diff += $diff;
    push @notes, "read $diff pages in $status->{title}" if $diff;
    $to_save{$id} = $status->{current_page}
      if grep { fc $_ eq 'currently-reading' } @{ $status->{shelves} };
  }

  $Logger->log([
    "on shelf %s, need %s pages read, have %s",
    $arg->{shelf}, $arg->{goal_pages}, $total_diff,
  ]);

  return {
    note  => join(q{; }, @notes),
    value => $JSON->encode(\%to_save),
    met_goal => $total_diff >= $arg->{goal_pages},
  };
}

my %GOODREAD_OVERRIDE = (
  '874055936' => 204, # Stylized
  '888491548' => 256,
  '938489037' => 218,
  '945306208' => 298,
  '1080170105' => 225,
  '1338597476' => 320,
  '1419735844' => 337, # Rust Programming Language
  '1503826885' => 275, # Eclipse Phase: After the Fall
);

sub _page_count_for_review {
  my ($self, $doc, $review_id, $title) = @_;

  return $GOODREAD_OVERRIDE{ $review_id }
    if exists $GOODREAD_OVERRIDE{ $review_id };

  my ($total_page_node) = $doc->getElementsByTagName('num_pages');
  return unless $total_page_node;
  return unless my $page_count = $total_page_node->textContent;

  return $page_count;
}

sub _get_review_status {
  my ($self, $review_id) = @_;

  my %status;

  my $res = LWP::UserAgent->new->get(
    sprintf 'https://www.goodreads.com/review/show.xml?key=%s&id=%s',
      $self->api_key,
      $review_id,
  );

  die "error getting review $review_id: " . $res->as_string
    unless $res->is_success;

  open my $fh, '<', \$res->decoded_content(charset => 'none')
    or die "error making handle to XML results: $!";

  my $doc = XML::LibXML->load_xml(IO => $fh);

  $status{shelves} = [
    map {; $_->getAttribute('name') } $doc->getElementsByTagName('shelf')
  ];

  my $title = ($doc->getElementsByTagName('title'))[0]->textContent;

  my $page_count = $self->_page_count_for_review($doc, $review_id, $title);

  unless ($page_count) {
    warn "couldn't figure out page count for book on review $review_id ($title)";
    warn "<<$doc>>\n";
    return;
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

