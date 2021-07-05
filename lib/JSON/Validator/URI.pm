package JSON::Validator::URI;
use Mojo::Base 'Mojo::URL';
use Exporter qw(import);

use Scalar::Util qw(blessed);

our @EXPORT_OK = qw(uri);

has nid => undef;
has nss => undef;

sub parse {
  my ($self, $url) = @_;

  # URL
  return $self->SUPER::parse($url) unless $url =~ m!^urn:(.*)$!i;

  # URN
  $self->scheme('urn');

  # TODO This regex is not 100% correct according to the 1997 changes regarding "?"
  return $self unless $1 =~ m/^([a-z0-9][a-z0-9-]{0,31}):([^#]+)(#(.*))?/;
  $self->fragment($4) if defined $3;
  return $self->nid($1)->nss($2);
}

sub to_abs {
  my $self = shift;
  my $abs  = $self->clone;
  return $abs if $abs->is_abs;

  my $base   = shift || $abs->base;
  my $scheme = $base->scheme // $abs->scheme // '';

  # URL
  return $self->SUPER::to_abs($base) unless 'urn' eq ($scheme // '');

  # URN
  return $abs->nid($base->nid)->nss($base->nss)->scheme('urn');
}

sub to_string {
  my $self = shift;

  # URL
  return $self->SUPER::to_string unless 'urn' eq ($self->scheme // '');

  # URN
  my $urn = sprintf 'urn:%s:%s', $self->nid, $self->nss;
  return $urn unless defined(my $fragment = $self->fragment);
  return "$urn#$fragment";
}

sub to_unsafe_string {
  my $self = shift;
  return 'urn' eq ($self->scheme // '') ? $self->to_string : $self->SUPER::to_unsafe_string;
}

sub uri {
  my ($uri, $base) = @_;
  return __PACKAGE__->new unless @_;
  $uri  = __PACKAGE__->new($uri) unless blessed $uri;
  $base = __PACKAGE__->new($base) if $base and !blessed $base;
  return $base ? $uri->to_abs($base) : $uri->clone;
}

1;

=encoding utf8

=head1 NAME

JSON::Validator::URI - Uniform Resource Identifier

=head1 SYNOPSIS

  use JSON::Validator::URI;

  my $urn = JSON::Validator::URI->new('urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f');
  my $url = JSON::Validator::URI->new('/foo');
  my $url = JSON::Validator::URI->new('https://mojolicious.org');

=head1 DESCRIPTION

L<JSON::Validator::URI> is a class for presenting both URL and URN.

This class is currently EXPERIMENTAL.

=head1 EXPORTED FUNCTIONS

=head2 uri

  $uri = uri;
  $uri = uri $orig, $base;

Returns a new L<JSON::Validator::URI> object from C<$orig> and C<$base>. Both
variables can be either a string or a L<JSON::Validator::URI> object.

=head1 ATTRIBUTES

L<JSON::Validator::URI> inherits all attributes from L<Mojo::URL> and
implements the following ones.

=head2 nid

  $str = $uri->nid;

Returns the NID part of a URN. Example "uuid" or "iban".

=head2 nss

  $str = $uri->nss;

Returns the NSS part of a URN. Example "6e8bc430-9c3a-11d9-9669-0800200c9a66".

=head1 METHODS

L<JSON::Validator::URI> inherits all methods from L<Mojo::URL> and implements
the following ones.

=head2 parse

See L<Mojo::URL/parse>.

=head2 to_abs

See L<Mojo::URL/to_abs>.

=head2 to_string

See L<Mojo::URL/to_string>.

=head2 to_unsafe_string

See L<Mojo::URL/to_unsafe_string>.

=head1 SEE ALSO

L<JSON::Validator>.

=cut
