package JSON::Validator::Schema::Draft201909;
use Mojo::Base 'JSON::Validator::Schema';

use JSON::Validator::Schema::Draft4;
use JSON::Validator::Schema::Draft6;
use JSON::Validator::Schema::Draft7;
use JSON::Validator::URI qw(uri);
use JSON::Validator::Util qw(E is_bool is_type json_pointer);
use Scalar::Util qw(refaddr);

has moniker       => 'draft2019';
has specification => 'https://json-schema.org/draft/2019-09/schema';

sub _build_formats {
  my $formats = shift->JSON::Validator::Schema::Draft7::_build_formats;
  $formats->{duration} = JSON::Validator::Formats->can('check_duration');
  $formats->{uuid}     = JSON::Validator::Formats->can('check_uuid');
  return $formats;
}

sub _normalize_ref { $_[1]->{'$recursiveRef'} // $_[1]->{'$ref'} }

sub _resolve_object {
  my ($self, $state, $schema, $refs, $found) = @_;

  if ($schema->{'$anchor'} && !ref $schema->{'$anchor'}) {
    my $id = uri(uri()->new->fragment($schema->{'$anchor'}), $state->{base_url});
    $self->store->add($id => $schema);
    $state = {%$state, base_url => $id->fragment(undef)->to_string};
  }
  if ($schema->{'$id'} and !ref $schema->{'$id'}) {
    my $id = uri $schema->{'$id'}, $state->{base_url};
    $self->store->add($id => $schema);
    $state = {%$state};                                 # make sure we don't mutate $state ref
    $state->{base_url} = $id->clone->fragment(undef);
  }

  if ($found->{'$recursiveRef'} = $schema->{'$recursiveRef'} && !ref $schema->{'$recursiveRef'}) {
    push @$refs, [$schema, $state];
  }
  if ($found->{'$ref'} = $schema->{'$ref'} && !ref $schema->{'$ref'}) {
    push @$refs, [$schema, $state];
  }

  return $state;
}

sub _state {
  my ($self, $curr, %override) = @_;

  my $schema = $override{schema} // $curr->{schema};
  my %seen;
  while (ref $schema eq 'HASH') {
    last unless my $ref = $schema->{'$ref'} || $schema->{'$recursiveRef'};
    last if ref $ref;
    my $addr = refaddr $schema;
    last if $seen{$addr}++;
    $schema = $self->_refs->{$addr}->{schema}
      // Carp::confess(qq(You have to call resolve() before validate() to lookup "$schema->{'$ref'}".));
  }

  return {%$curr, %override, schema => $schema};
}

sub _state_for_get {
  my ($self, $schema, $state) = @_;
  return $self->_refs->{refaddr($schema)}
    if ref $schema eq 'HASH'
    and (($schema->{'$ref'} and !ref $schema->{'$ref'})
    or ($schema->{'$recursiveRef'} and !ref $schema->{'$recursiveRef'}));
  return {%$state, schema => $schema};
}

sub _validate_type_array_contains {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  return unless exists $schema->{contains};
  return if defined $schema->{minContains} and $schema->{minContains} == 0;

  my ($n_valid, @e, @errors) = (0);
  for my $i (0 .. @$data - 1) {
    my @tmp = $self->_validate($data->[$i], $self->_state($state, path => "$path/$i", schema => $schema->{contains}));
    @tmp ? push @e, \@tmp : $n_valid++;
  }

  push @errors, map {@$_} @e if @e >= @$data;
  push @errors, E $path, [array => 'maxContains', int @$data, $schema->{maxContains}]
    if exists $schema->{maxContains} and $n_valid > $schema->{maxContains};
  push @errors, E $path, [array => 'minContains', int @$data, $schema->{minContains}]
    if $schema->{minContains} and $n_valid < $schema->{minContains};
  push @errors, E $path, [array => 'contains'] if not @$data;
  return @errors;
}

sub _validate_type_object_dependencies {
  my ($self, $data, $state) = @_;
  my $dependencies = $state->{schema}{dependentSchemas} || {};
  my @errors;

  for my $k (keys %$dependencies) {
    next if not exists $data->{$k};
    if (ref $dependencies->{$k} eq 'ARRAY') {
      push @errors,
        map { E json_pointer($state->{path}, $_), [object => dependencies => $k] }
        grep { !exists $data->{$_} } @{$dependencies->{$k}};
    }
    else {
      push @errors, $self->_validate($data, $self->_state($state, schema => $dependencies->{$k}));
    }
  }

  $dependencies = $state->{schema}{dependentRequired} || {};
  for my $k (keys %$dependencies) {
    next if not exists $data->{$k};
    push @errors,
      map { E json_pointer($state->{path}, $_), [object => dependencies => $k] }
      grep { !exists $data->{$_} } @{$dependencies->{$k}};
  }

  return @errors;
}

*_bundle_ref_path                 = \&JSON::Validator::Schema::Draft7::_bundle_ref_path;
*_validate_number_max             = \&JSON::Validator::Schema::Draft6::_validate_number_max;
*_validate_number_min             = \&JSON::Validator::Schema::Draft6::_validate_number_min;
*_validate_type_array             = \&JSON::Validator::Schema::Draft6::_validate_type_array;
*_validate_type_array_items       = \&JSON::Validator::Schema::Draft4::_validate_type_array_items;
*_validate_type_array_min_max     = \&JSON::Validator::Schema::Draft4::_validate_type_array_min_max;
*_validate_type_array_unique      = \&JSON::Validator::Schema::Draft4::_validate_type_array_unique;
*_validate_type_object            = \&JSON::Validator::Schema::Draft6::_validate_type_object;
*_validate_type_object_min_max    = \&JSON::Validator::Schema::Draft4::_validate_type_object_min_max;
*_validate_type_object_names      = \&JSON::Validator::Schema::Draft6::_validate_type_object_names;
*_validate_type_object_properties = \&JSON::Validator::Schema::Draft4::_validate_type_object_properties;

1;

=encoding utf8

=head1 NAME

JSON::Validator::Schema::Draft201909 - JSON-Schema Draft 2019-09

=head1 SYNOPSIS

See L<JSON::Validator::Schema/SYNOPSIS>.

=head1 DESCRIPTION

This class represents
L<https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>.

Support for parsing the draft is not yet complete. Look at
L<https://github.com/mojolicious/json-validator/blob/master/t/draft2019-09-acceptance.t>
for the most recent overview of what is not yet supported.

Currently less than 1% of the official test suite gets skipped. Here is a list of known
limitations:

=over 2

=item * Float and integers are equal up to 64-bit representation limits

This module is unable to say that the 64-bit number "9007199254740992.0" is the
same as "9007199254740992".

=item * unevaluatedItems

See L</unevaluatedProperties>

=item * unevaluatedProperties

L</unevaluatedItems> and L</unevaluatedProperties> needs to track what has been
valdated or not using annotations. This is not yet supported.

=item * $recursiveAnchor

Basic support for C<$recursiveRef> is supported, but using it together with
C<$recursiveAnchor> is not.

=back

=head1 ATTRIBUTES

=head2 specification

  my $str = $schema->specification;

Defaults to "L<https://json-schema.org/draft/2019-09/schema>".

=head1 SEE ALSO

L<JSON::Validator::Schema>.

=cut
