package JSON::Validator::Store;
use Mojo::Base -base;

use Mojo::Exception;
use Mojo::File qw(path);
use Mojo::JSON;
use Mojo::UserAgent;
use Mojo::Util qw(url_unescape);
use JSON::Validator::Schema;
use JSON::Validator::Util qw(data_section);

use constant BUNDLED_PATH  => path(path(__FILE__)->dirname, 'cache')->to_string;
use constant CASE_TOLERANT => File::Spec->case_tolerant;

die $@ unless eval q(package JSON::Validator::Exception; use Mojo::Base 'Mojo::Exception'; 1);

has cache_paths => sub { [split(/:/, $ENV{JSON_VALIDATOR_CACHE_PATH} || ''), BUNDLED_PATH] };
has schemas     => sub { +{} };

has ua => sub {
  my $ua = Mojo::UserAgent->new;
  $ua->proxy->detect;
  return $ua->max_redirects(3);
};

sub add {
  my ($self, $id, $schema) = @_;
  $id =~ s!(.)#$!$1!;
  $self->schemas->{$id} = $schema;
  return $id;
}

sub exists {
  my ($self, $id) = @_;
  return undef unless defined $id;
  $id =~ s!(.)#$!$1!;
  return $self->schemas->{$id} && $id;
}

sub get {
  my ($self, $id) = @_;
  return undef unless defined $id;
  $id =~ s!(.)#$!$1!;
  return $self->schemas->{$id};
}

sub load {
  return
       $_[0]->_load_from_url($_[1])
    || $_[0]->_load_from_data($_[1])
    || $_[0]->_load_from_text($_[1])
    || $_[0]->_load_from_file($_[1])
    || $_[0]->_load_from_app($_[1])
    || $_[0]->get($_[1])
    || _raise("Unable to load schema $_[1]");
}

sub _load_from_app {
  return undef unless $_[1] =~ m!^/!;

  my ($self, $url) = @_;
  my $id;
  return undef unless $self->ua->server->app;
  return $id if $id = $self->exists($url);

  my $tx  = $self->ua->get($url);
  my $err = $tx->error && $tx->error->{message};
  _raise($err) if $err;
  return $self->add($url => _parse($tx->res->body));
}

sub _load_from_data {
  return undef unless $_[1] =~ m!^data://([^/]*)/(.*)!;

  my ($self, $url) = @_;
  my $id;
  return $id if $id = $self->exists($url);

  my ($class, $file) = ($1, $2);    # data://([^/]*)/(.*)
  my $text = data_section $class, $file, {encoding => 'UTF-8'};
  _raise("Could not find $url") unless $text;
  return $self->add($url => _parse($text));
}

sub _load_from_file {
  my ($self, $file) = @_;

  $file =~ s!^file://!!;
  $file =~ s!#$!!;
  $file = path(split '/', url_unescape $file);
  return undef unless -e $file;

  $file = $file->realpath;
  my $id = Mojo::URL->new->scheme('file')->host('')->path(CASE_TOLERANT ? lc $file : "$file");
  return $self->exists($id) || $self->add($id => _parse($file->slurp));
}

sub _load_from_text {
  my ($self, $text) = @_;
  my $is_scalar_ref = ref $text eq 'SCALAR';
  return undef unless $is_scalar_ref or $text =~ m!^\s*(?:---|\{)!s;

  my $id = sprintf 'urn:text:%s', Mojo::Util::md5_sum($is_scalar_ref ? $$text : $text);
  return $self->exists($id) || $self->add($id => _parse($is_scalar_ref ? $$text : $text));
}

sub _load_from_url {
  return undef unless $_[1] =~ m!^https?://!;

  my ($self, $url) = @_;
  my $id;
  return $id if $id = $self->exists($url);

  $url = Mojo::URL->new($url)->fragment(undef);
  return $id if $id = $self->exists($url);

  my $cache_path = $self->cache_paths->[0];
  my $cache_file = Mojo::Util::md5_sum("$url");
  for (@{$self->cache_paths}) {
    my $path = path $_, $cache_file;
    return $self->add($url => _parse($path->slurp)) if -r $path;
  }

  my $tx  = $self->ua->get($url);
  my $err = $tx->error && $tx->error->{message};
  _raise($err) if $err;

  if ($cache_path and $cache_path ne BUNDLED_PATH and -w $cache_path) {
    $cache_file = path $cache_path, $cache_file;
    $cache_file->spurt($tx->res->body);
  }

  return $self->add($url => _parse($tx->res->body));
}

sub _parse {
  return Mojo::JSON::decode_json($_[0]) if $_[0] =~ m!^\s*\{!s;
  return JSON::Validator::Util::_yaml_load($_[0]);
}

sub _raise { die JSON::Validator::Exception->new(@_)->trace }

1;

=encoding utf8

=head1 NAME

JSON::Validator::Store - Load and caching JSON schemas

=head1 SYNOPSIS

  use JSON::Validator;
  my $jv = JSON::Validator->new;
  $jv->store->add("urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f" => {...});
  $jv->store->load("http://api.example.com/my/schema.json");

=head1 DESCRIPTION

L<JSON::Validator::Store> is a class for loading and caching JSON-Schemas.

=head1 ATTRIBUTES

=head2 cache_paths

  my $store     = $store->cache_paths(\@paths);
  my $array_ref = $store->cache_paths;

A list of directories to where cached specifications are stored. Defaults to
C<JSON_VALIDATOR_CACHE_PATH> environment variable and the specs that is bundled
with this distribution.

C<JSON_VALIDATOR_CACHE_PATH> can be a list of directories, each separated by ":".

See L<JSON::Validator/Bundled specifications> for more details.

=head2 schemas

  my $hash_ref = $store->schemas;
  my $store = $store->schemas({});

Hold the schemas as data structures. The keys are schema "id".

=head2 ua

  my $ua    = $store->ua;
  my $store = $store->ua(Mojo::UserAgent->new);

Holds a L<Mojo::UserAgent> object, used by L</schema> to load a JSON schema
from remote location.

The default L<Mojo::UserAgent> will detect proxy settings and have
L<Mojo::UserAgent/max_redirects> set to 3.

=head1 METHODS

=head2 add

  my $normalized_id = $store->add($id => \%schema);

Used to add a schema data structure. Note that C<$id> might not be the same as
C<$normalized_id>.

=head2 exists

  my $normalized_id = $store->exists($id);

Returns a C<$normalized_id> if it is present in the L</schemas>.

=head2 get

  my $schema = $store->get($normalized_id);

Used to retrieve a C<$schema> added by L</add> or L</load>.

=head2 load

  my $normalized_id = $store->load('https://...');
  my $normalized_id = $store->load('data://main/foo.json');
  my $normalized_id = $store->load('---\nid: yaml');
  my $normalized_id = $store->load('{"id":"yaml"}');
  my $normalized_id = $store->load(\$text);
  my $normalized_id = $store->load('/path/to/foo.json');
  my $normalized_id = $store->load('file:///path/to/foo.json');
  my $normalized_id = $store->load('/load/from/ua-server-app');

Can load a C<$schema> from many different sources. The input can be a string or
a string-like object, and the L</load> method will try to resolve it in the
order listed in above.

Loading schemas from C<$text> will generate an C<$normalized_id> in L</schemas>
looking like "urn:text:$text_checksum". This might change in the future!

Loading files from disk will result in a C<$normalized_id> that always start
with "file://".

Loading can also be done with relative path, which will then load from:

  $store->ua->server->app;

This method is EXPERIMENTAL, but unlikely to change significantly.

=head1 SEE ALSO

L<JSON::Validator>.

=cut
