package JSON::Validator::Schema::Draft201909;
use Mojo::Base 'JSON::Validator::Schema';

use JSON::Validator::Schema::Draft4;
use JSON::Validator::Schema::Draft6;
use JSON::Validator::Schema::Draft7;
use JSON::Validator::Util qw(E is_bool is_type json_pointer);
use Scalar::Util qw(blessed refaddr);

my $ANCHOR_RE = qr{[A-Za-z][A-Za-z0-9:._-]*};

has specification => 'https://json-schema.org/draft/2019-09/schema';
has _anchors      => sub { +{} };

sub _build_formats {
  my $formats = shift->JSON::Validator::Schema::Draft7::_build_formats;
  $formats->{duration} = JSON::Validator::Formats->can('check_duration');
  $formats->{uuid}     = JSON::Validator::Formats->can('check_uuid');
  return $formats;
}

sub _definitions_path_for_ref { ['$defs'] }
sub _id_key                   {'$id'}

sub _find_and_resolve_refs {
  my ($self, $base_url, $root) = @_;

  my (@topics, @recursive_refs, @refs, %seen) = ([$base_url, $root]);
  while (@topics) {
    my ($base_url, $topic) = @{shift @topics};

    if (is_type $topic, 'ARRAY') {
      push @topics, map { [$base_url, $_] } @$topic;
    }
    elsif (is_type $topic, 'HASH') {
      next if $seen{refaddr($topic)}++;

      my $base_url = $base_url;    # do not change the global $base_url
      if ($topic->{'$id'} and !ref $topic->{'$id'}) {
        my $id = Mojo::URL->new($topic->{'$id'});
        $id = $id->to_abs($base_url) unless $id->is_abs;
        $self->store->add($id->to_string => $topic);
        $base_url = $id;
      }

      if ($topic->{'$anchor'} && !ref $topic->{'$anchor'}) {
        $self->_anchors->{$topic->{'$anchor'}} = $topic;
      }

      my $is_tied           = tied %$topic;
      my $has_ref           = !$is_tied && $topic->{'$ref'}          && !ref $topic->{'$ref'}          ? 1 : 0;
      my $has_recursive_ref = !$is_tied && $topic->{'$recursiveRef'} && !ref $topic->{'$recursiveRef'} ? 1 : 0;
      push @refs,           [$base_url, $topic] if $has_ref;
      push @recursive_refs, [$base_url, $topic] if $has_recursive_ref;

      for my $key (keys %$topic) {
        next unless ref $topic->{$key};
        next if $has_ref           and $key eq '$ref';
        next if $has_recursive_ref and $key eq '$recursiveRef';
        push @topics, [$base_url, $topic->{$key}];
      }
    }
  }

  %seen = ();
  while (@refs) {
    my ($base_url, $topic) = @{shift @refs};
    next if is_bool $topic;
    next if !$topic->{'$ref'} or ref $topic->{'$ref'};
    my $base = Mojo::URL->new($base_url || $base_url)->fragment(undef);
    my ($other, $ref_url, $fqn) = $self->_resolve_ref($topic->{'$ref'}, $base, $root);
    next if $seen{$fqn}++ and tied %$topic;
    tie %$topic, 'JSON::Validator::Ref', $other, $topic, "$fqn";
    push @refs, [$fqn, $other];
  }

  %seen = ();
  while (@recursive_refs) {
    my ($base_url, $topic) = @{shift @recursive_refs};
    my $base = Mojo::URL->new($base_url || $base_url)->fragment(undef);
    my ($other, $ref_url, $fqn) = $self->_resolve_ref($topic->{'$recursiveRef'}, $base, $root);
    next if $seen{$fqn}++ and tied %$topic;
    tie %$topic, 'JSON::Validator::Ref', $other, $topic, "$fqn";
  }
}

sub _resolve_ref {
  my ($self, $ref_url, $base_url, $root) = @_;
  return $self->_anchors->{$1}, $ref_url, $ref_url if $ref_url =~ m!^#($ANCHOR_RE)$!;
  return $self->SUPER::_resolve_ref($ref_url, $base_url, $root);
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
