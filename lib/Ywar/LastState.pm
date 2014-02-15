use 5.14.0;
package Ywar::LastState;
use Moose;

has measurement => (
  is => 'ro',
  predicate => 'has_measurement',
);

has completion => (
  is => 'ro',
  predicate => 'has_completion',
);

1;
