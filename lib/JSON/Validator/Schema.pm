package JSON::Validator::Schema;
use Mojo::Base 'JSON::Validator';    # TODO: Change this to "use Mojo::Base -base"

use Carp qw(carp confess);
use JSON::Validator::Formats;
use JSON::Validator::Util qw(E data_checksum data_type is_type json_pointer prefix_errors schema_type);
use List::Util qw(uniq);
use Mojo::JSON qw(false true);
use Mojo::JSON::Pointer;
use Scalar::Util qw(blessed refaddr);

use constant RECURSION_LIMIT => $ENV{JSON_VALIDATOR_RECURSION_LIMIT} || 100;

has errors => sub {
  my $self      = shift;
  my $url       = $self->specification || 'http://json-schema.org/draft-04/schema#';
  my $validator = $self->new(%$self)->resolve($url);

  return [$validator->validate($self->resolve->data)];
};

has formats => sub { shift->_build_formats };

has id => sub {
  my $data = shift->data;
  return is_type($data, 'HASH') ? $data->{'$id'} || $data->{id} || '' : '';
};

has moniker => sub {
  my $self = shift;
  return "draft$1" if $self->specification =~ m!draft-(\d+)!;
  return '';
};

has specification => sub {
  my $data = shift->data;
  is_type($data, 'HASH') ? $data->{'$schema'} || $data->{schema} || '' : '';
};

sub bundle {
  my $self   = shift;
  my $params = shift || {};
  return $self->new(%$self)->data($self->SUPER::bundle({schema => $self, %$params}));
}

sub contains {
  state $p = Mojo::JSON::Pointer->new;
  return $p->data(shift->{data})->contains(@_);
}

sub data {
  my $self = shift;
  return $self->{data} //= {} unless @_;
  $self->{data} = shift;
  delete $self->{errors};
  return $self;
}

sub get {
  state $p = Mojo::JSON::Pointer->new;
  return $p->data(shift->{data})->get(@_) if @_ == 2 and ref $_[1] ne 'ARRAY';
  return JSON::Validator::Util::schema_extract(shift->data, @_);
}

sub is_invalid { !!@{shift->errors} }

sub load_and_validate_schema { Carp::confess('load_and_validate_schema(...) is unsupported.') }

sub new {
  return shift->SUPER::new(@_) if @_ % 2;
  my ($class, $data) = (shift, shift);
  return $class->SUPER::new(@_)->resolve($data);
}

sub resolve {
  my $self = shift;
  return $self->data($self->_resolve(@_ ? shift : $self->{data}));
}

sub validate {
  my ($self, $data, $schema) = @_;
  my %state  = (path => '', root => $self->data, schema => $schema // $self->data, seen => {});
  my @errors = sort { $a->path cmp $b->path } $self->_validate($_[1], $self->_state(\%state));
  return @errors;
}

sub schema { $_[0]->can('data') ? $_[0] : $_[0]->SUPER::schema }

sub _build_formats {
  return {
    'byte'                  => JSON::Validator::Formats->can('check_byte'),
    'date'                  => JSON::Validator::Formats->can('check_date'),
    'date-time'             => JSON::Validator::Formats->can('check_date_time'),
    'duration'              => JSON::Validator::Formats->can('check_duration'),
    'double'                => JSON::Validator::Formats->can('check_double'),
    'email'                 => JSON::Validator::Formats->can('check_email'),
    'float'                 => JSON::Validator::Formats->can('check_float'),
    'hostname'              => JSON::Validator::Formats->can('check_hostname'),
    'idn-email'             => JSON::Validator::Formats->can('check_idn_email'),
    'idn-hostname'          => JSON::Validator::Formats->can('check_idn_hostname'),
    'int32'                 => JSON::Validator::Formats->can('check_int32'),
    'int64'                 => JSON::Validator::Formats->can('check_int64'),
    'ipv4'                  => JSON::Validator::Formats->can('check_ipv4'),
    'ipv6'                  => JSON::Validator::Formats->can('check_ipv6'),
    'iri'                   => JSON::Validator::Formats->can('check_iri'),
    'iri-reference'         => JSON::Validator::Formats->can('check_iri_reference'),
    'json-pointer'          => JSON::Validator::Formats->can('check_json_pointer'),
    'regex'                 => JSON::Validator::Formats->can('check_regex'),
    'relative-json-pointer' => JSON::Validator::Formats->can('check_relative_json_pointer'),
    'time'                  => JSON::Validator::Formats->can('check_time'),
    'uri'                   => JSON::Validator::Formats->can('check_uri'),
    'uri-reference'         => JSON::Validator::Formats->can('check_uri_reference'),
    'uri-reference'         => JSON::Validator::Formats->can('check_uri_reference'),
    'uri-template'          => JSON::Validator::Formats->can('check_uri_template'),
    'uuid'                  => JSON::Validator::Formats->can('check_uuid'),
  };
}

sub _definitions_path_for_ref { ['definitions'] }

sub _id_key {'id'}

sub _register_root_schema {
  my ($self, $id, $schema) = @_;
  $self->SUPER::_register_root_schema($id => $schema);
  $self->id($id) unless $self->id;
}

sub _state {
  my ($self, $curr, %override) = @_;

  my ($schema, @guard) = ($override{schema} // $curr->{schema});
  while (1) {
    last unless ref $schema eq 'HASH';
    last unless my $tied = tied %$schema;
    push @guard, $tied->ref;
    confess "Seems like you have a circular reference: @guard" if @guard > RECURSION_LIMIT;
    $schema = $tied->schema;
  }

  return {%$curr, %override, schema => $schema};
}

sub _validate {
  my ($self, $data, $state) = @_;
  my $schema = $state->{schema};
  return $schema ? () : E $state->{path}, [not => 'not'] if is_type $schema, 'BOOL';

  my @errors;
  if ($self->recursive_data_protection) {
    my $seen_addr = join ':', refaddr($schema), (ref $data ? refaddr $data : ++$state->{seen}{scalar});
    return @{$state->{seen}{$seen_addr}} if $state->{seen}{$seen_addr};    # Avoid recursion
    $state->{seen}{$seen_addr} = \@errors;
  }

  local $_[1] = $data->TO_JSON if blessed $data and $data->can('TO_JSON');

  if ($schema->{not}) {
    my @e = $self->_validate($_[1], $self->_state($state, schema => $schema->{not}));
    push @errors, E $state->{path}, [not => 'not'] unless @e;
  }
  if (my $rules = $schema->{allOf}) {
    push @errors, $self->_validate_all_of($_[1], $self->_state($state, schema => $rules));
  }
  if (my $rules = $schema->{anyOf}) {
    push @errors, $self->_validate_any_of($_[1], $self->_state($state, schema => $rules));
  }
  if (my $rules = $schema->{oneOf}) {
    push @errors, $self->_validate_one_of($_[1], $self->_state($state, schema => $rules));
  }
  if (exists $schema->{if}) {
    my $rules = !$schema->{if}
      || $self->_validate($_[1], $self->_state($state, schema => $schema->{if})) ? $schema->{else} : $schema->{then};
    push @errors, $self->_validate($_[1], $self->_state($state, schema => $rules // {}));
  }

  my $type = $schema->{type} || schema_type $schema, $_[1];
  if (ref $type eq 'ARRAY') {
    push @errors,
      $self->_validate_any_of_types($_[1], $self->_state($state, schema => [map { +{%$schema, type => $_} } @$type]));
  }
  elsif ($type) {
    my $method = sprintf '_validate_type_%s', $type;
    push @errors, $self->$method($_[1], $state);
  }

  return @errors if @errors;

  if (exists $schema->{const}) {
    push @errors, $self->_validate_type_const($_[1], $state);
  }
  if ($schema->{enum}) {
    push @errors, $self->_validate_type_enum($_[1], $state);
  }

  return @errors;
}

sub _validate_all_of {
  my ($self, $data, $state) = @_;
  my (@errors, @errors_with_prefix);

  my $i = 0;
  for my $rule (@{$state->{schema}}) {
    next unless my @e = $self->_validate($_[1], $self->_state($state, schema => $rule));
    push @errors,             @e;
    push @errors_with_prefix, [$i, @e];
  }
  continue {
    $i++;
  }

  return if not @errors;

  return prefix_errors(allOf => @errors_with_prefix)
    if @errors == 1
    or (grep { $_->details->[1] ne 'type' or $_->path ne ($state->{path} || '/') } @errors);

  # combine all 'type' errors at the base path together
  my @details    = map $_->details, @errors;
  my $want_types = join '/', uniq map $_->[0], @details;
  return E $state->{path}, [allOf => type => $want_types, $details[-1][2]];
}

sub _validate_any_of_types {
  my ($self, $data, $state) = @_;
  my @errors;

  for my $rule (@{$state->{schema}}) {
    return unless my @e = $self->_validate($_[1], $self->_state($state, schema => $rule));
    push @errors, @e;
  }

  # favor a non-type error from one of the rules
  if (my @e = grep { $_->details->[1] ne 'type' or $_->path ne ($state->{path} || '/') } @errors) {
    return @e;
  }

  # the type didn't match any of the rules: combine the errors together
  my @details    = map $_->details, @errors;
  my $want_types = join '/', uniq map $_->[0], @details;
  return E $state->{path}, [$want_types => 'type', $details[-1][2]];
}

sub _validate_any_of {
  my ($self, $data, $state) = @_;
  my (@errors, @errors_with_prefix);

  my $i = 0;
  for my $rule (@{$state->{schema}}) {
    return unless my @e = $self->_validate($_[1], $self->_state($state, schema => $rule));
    push @errors,             @e;
    push @errors_with_prefix, [$i, @e];
  }
  continue {
    $i++;
  }

  return prefix_errors(anyOf => @errors_with_prefix)
    if @errors == 1
    or (grep { $_->details->[1] ne 'type' or $_->path ne ($state->{path} || '/') } @errors);

  # combine all 'type' errors at the base path together
  my @details    = map $_->details, @errors;
  my $want_types = join '/', uniq map $_->[0], @details;
  return E $state->{path}, [anyOf => type => $want_types, $details[-1][2]];
}

sub _validate_one_of {
  my ($self,   $data, $state) = @_;
  my ($path,   $schema) = @$state{qw(path schema)};
  my (@errors, @errors_with_prefix);

  my ($i, @passed) = (0);
  for my $rule (@{$state->{schema}}) {
    my @e = $self->_validate($_[1], $self->_state($state, schema => $rule));
    push @passed,             $i and next unless @e;
    push @errors_with_prefix, [$i, @e];
    push @errors,             @e;
  }
  continue {
    $i++;
  }

  return if @passed == 1;
  return E $path, [oneOf => 'all_rules_match'] unless @errors;
  return E $path, [oneOf => 'n_rules_match', join(', ', @passed)] if @passed;

  return prefix_errors(oneOf => @errors_with_prefix)
    if @errors == 1
    or (grep { $_->details->[1] ne 'type' or $_->path ne ($path || '/') } @errors);

  # the type didn't match any of the rules: combine the errors together
  my @details    = map $_->details, @errors;
  my $want_types = join '/', uniq map $_->[0], @details;
  return E $path, [oneOf => type => $want_types, $details[-1][2]];
}

sub _validate_number_max {
  my ($self, $value, $state, $expected) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  my @errors;

  my $cmp_with = $schema->{exclusiveMaximum} // '';
  if (is_type $cmp_with, 'BOOL') {
    push @errors, E $path, [$expected => ex_maximum => $value, $schema->{maximum}] unless $value < $schema->{maximum};
  }
  elsif (is_type $cmp_with, 'NUM') {
    push @errors, E $path, [$expected => ex_maximum => $value, $cmp_with] unless $value < $cmp_with;
  }

  if (exists $schema->{maximum}) {
    my $cmp_with = $schema->{maximum};
    push @errors, E $path, [$expected => maximum => $value, $cmp_with] unless $value <= $cmp_with;
  }

  return @errors;
}

sub _validate_number_min {
  my ($self, $value, $state, $expected) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  my @errors;

  my $cmp_with = $schema->{exclusiveMinimum} // '';
  if (is_type $cmp_with, 'BOOL') {
    push @errors, E $path, [$expected => ex_minimum => $value, $schema->{minimum}] unless $value > $schema->{minimum};
  }
  elsif (is_type $cmp_with, 'NUM') {
    push @errors, E $path, [$expected => ex_minimum => $value, $cmp_with] unless $value > $cmp_with;
  }

  if (exists $schema->{minimum}) {
    my $cmp_with = $schema->{minimum};
    push @errors, E $path, [$expected => minimum => $value, $cmp_with] unless $value >= $cmp_with;
  }

  return @errors;
}

sub _validate_type_enum {
  my ($self, $data, $state) = @_;
  my $enum = $state->{schema}{enum};
  my $m    = data_checksum $data;

  for my $i (@$enum) {
    return if $m eq data_checksum $i;
  }

  $enum = join ', ', map { (!defined or ref) ? Mojo::JSON::encode_json($_) : $_ } @$enum;
  return E $state->{path}, [enum => enum => $enum];
}

sub _validate_type_const {
  my ($self, $data, $state) = @_;
  my $const = $state->{schema}{const};

  return if data_checksum($data) eq data_checksum($const);
  return E $state->{path}, [const => const => Mojo::JSON::encode_json($const)];
}

sub _validate_format {
  my ($self, $value, $state) = @_;
  my $format = $state->{schema}{format};
  my $code   = $self->formats->{$format};
  return do { warn "Format rule for '$format' is missing"; return } unless $code;
  return unless my $err = $code->($value);
  return E $state->{path}, [format => $format, $err];
}

sub _validate_type_any { }

sub _validate_type_array {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  my @errors;

  if (ref $data ne 'ARRAY') {
    return E $path, [array => type => data_type $data];
  }
  if (defined $schema->{minItems} and $schema->{minItems} > @$data) {
    push @errors, E $path, [array => minItems => int(@$data), $schema->{minItems}];
  }
  if (defined $schema->{maxItems} and $schema->{maxItems} < @$data) {
    push @errors, E $path, [array => maxItems => int(@$data), $schema->{maxItems}];
  }
  if ($schema->{uniqueItems}) {
    my %uniq;
    for (@$data) {
      next if !$uniq{data_checksum($_)}++;
      push @errors, E $path, [array => 'uniqueItems'];
      last;
    }
  }

  if (exists $schema->{contains}) {
    my @e;
    for my $i (0 .. @$data - 1) {
      my @tmp = $self->_validate($data->[$i], $self->_state($state, path => "$path/$i", schema => $schema->{contains}));
      push @e, \@tmp if @tmp;
    }
    push @errors, map {@$_} @e if @e >= @$data;
    push @errors, E $path, [array => 'contains'] if not @$data;
  }

  if (ref $schema->{items} eq 'ARRAY') {
    my $additional_items = $schema->{additionalItems} // {};
    my @rules            = @{$schema->{items}};

    if ($additional_items) {
      push @rules, $additional_items while @rules < @$data;
    }

    if (@rules >= @$data) {
      for my $i (0 .. @$data - 1) {
        push @errors, $self->_validate($data->[$i], $self->_state($state, path => "$path/$i", schema => $rules[$i]));
      }
    }
    elsif (!$additional_items) {
      push @errors, E $path, [array => additionalItems => int(@$data), int(@rules)];
    }
  }
  elsif (exists $schema->{items}) {
    for my $i (0 .. @$data - 1) {
      push @errors,
        $self->_validate($data->[$i], $self->_state($state, path => "$path/$i", schema => $schema->{items}));
    }
  }

  return @errors;
}

sub _validate_type_boolean {
  my ($self, $value, $state) = @_;

  # String that looks like a boolean
  if (defined $value and $self->{coerce}{booleans}) {
    $_[1] = false if $value =~ m!^(0|false|)$!;
    $_[1] = true  if $value =~ m!^(1|true)$!;
  }

  return if is_type $_[1], 'BOOL';
  return E $state->{path}, [boolean => type => data_type $value];
}

sub _validate_type_integer {
  my ($self, $value, $state) = @_;
  my @errors = $self->_validate_type_number($_[1], $state, 'integer');

  return @errors if @errors;
  return         if $value =~ /^-?\d+$/;
  return E $state->{path}, [integer => type => data_type $value];
}

sub _validate_type_null {
  my ($self, $value, $state) = @_;

  return unless defined $value;
  return E $state->{path}, [null => type => data_type $value];
}

sub _validate_type_number {
  my ($self, $value, $state, $expected) = @_;
  my @errors;

  $expected ||= 'number';

  if (!defined $value or ref $value) {
    return E $state->{path}, [$expected => type => data_type $value];
  }
  unless (is_type $value, 'NUM') {
    return E $state->{path}, [$expected => type => data_type $value]
      if !$self->{coerce}{numbers} or $value !~ /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
    $_[1] = 0 + $value;    # coerce input value
  }

  push @errors, $self->_validate_format($value, $state) if $state->{schema}{format};
  push @errors, $self->_validate_number_max($value, $state, $expected);
  push @errors, $self->_validate_number_min($value, $state, $expected);

  my $d = $state->{schema}{multipleOf};
  push @errors, E $state->{path}, [$expected => multipleOf => $d] if $d and ($value / $d) =~ /\.[^0]+$/;

  return @errors;
}

sub _validate_type_object {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};

  return E $path, [object => type => data_type $data] unless ref $data eq 'HASH';

  my @errors;
  my @dkeys = sort keys %$data;
  if (defined $schema->{maxProperties} and $schema->{maxProperties} < @dkeys) {
    push @errors, E $path, [object => maxProperties => int(@dkeys), $schema->{maxProperties}];
  }
  if (defined $schema->{minProperties} and $schema->{minProperties} > @dkeys) {
    push @errors, E $path, [object => minProperties => int(@dkeys), $schema->{minProperties}];
  }
  if (exists $schema->{propertyNames}) {
    for my $name (keys %$data) {
      next unless my @e = $self->_validate($name, $self->_state($state, schema => $schema->{propertyNames}));
      push @errors, prefix_errors propertyName => map [$name, $_], @e;
    }
  }

  my %rules;
  for my $k (keys %{$schema->{properties} || {}}) {
    my $r = $schema->{properties}{$k};
    push @{$rules{$k}}, $r;
    if ($self->{coerce}{defaults} and ref $r eq 'HASH' and exists $r->{default} and !exists $data->{$k}) {
      $data->{$k} = $r->{default};
    }
  }

  for my $p (keys %{$schema->{patternProperties} || {}}) {
    my $r = $schema->{patternProperties}{$p};
    push @{$rules{$_}}, $r for sort grep { $_ =~ /$p/ } @dkeys;
  }

  my $additional = exists $schema->{additionalProperties} ? $schema->{additionalProperties} : {};
  if ($additional) {
    $additional = {} unless is_type $additional, 'HASH';
    $rules{$_} ||= [$additional] for @dkeys;
  }
  elsif (my @k = grep { !$rules{$_} } @dkeys) {
    local $" = ', ';
    return E $path, [object => additionalProperties => join ', ', sort @k];
  }

  for my $k (sort { $a cmp $b } uniq @{$schema->{required} || []}) {
    next if exists $data->{$k};
    push @errors, E json_pointer($path, $k), [object => 'required'];
    delete $rules{$k};
  }

  my $dependencies = $schema->{dependencies} || {};
  for my $k (keys %$dependencies) {
    next if not exists $data->{$k};
    if (ref $dependencies->{$k} eq 'ARRAY') {
      push @errors,
        map { E json_pointer($path, $_), [object => dependencies => $k] }
        grep { !exists $data->{$_} } @{$dependencies->{$k}};
    }
    elsif (ref $dependencies->{$k} eq 'HASH') {
      push @errors, $self->_validate_type_object($data, $self->_state($state, schema => $schema->{dependencies}{$k}));
    }
  }

  for my $k (sort keys %rules) {
    for my $r (@{$rules{$k}}) {
      next unless exists $data->{$k};
      my $s2 = $self->_state($state, path => json_pointer($path, $k), schema => $r);
      my @e  = $self->_validate($data->{$k}, $s2);
      push @errors, @e;
      next if @e or !is_type $r, 'HASH';
      push @errors, $self->_validate_type_enum($data->{$k}, $s2)  if $r->{enum};
      push @errors, $self->_validate_type_const($data->{$k}, $s2) if $r->{const};
    }
  }

  return @errors;
}

sub _validate_type_string {
  my ($self, $value, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  my @errors;

  if (!$schema->{type} and !defined $value) {
    return;
  }
  if (!defined $value or ref $value) {
    return E $path, [string => type => data_type $value];
  }
  if (B::svref_2object(\$value)->FLAGS & (B::SVp_IOK | B::SVp_NOK) and 0 + $value eq $value and $value * 0 == 0) {
    return E $path, [string => type => data_type $value] unless $self->{coerce}{strings};
    $_[1] = "$value";    # coerce input value
  }
  if ($schema->{format}) {
    push @errors, $self->_validate_format($value, $state);
  }
  if (defined $schema->{maxLength}) {
    if (length($value) > $schema->{maxLength}) {
      push @errors, E $path, [string => maxLength => length($value), $schema->{maxLength}];
    }
  }
  if (defined $schema->{minLength}) {
    if (length($value) < $schema->{minLength}) {
      push @errors, E $path, [string => minLength => length($value), $schema->{minLength}];
    }
  }
  if (defined $schema->{pattern}) {
    my $p = $schema->{pattern};
    push @errors, E $path, [string => pattern => $p] unless $value =~ /$p/;
  }

  return @errors;
}

1;

=encoding utf8

=head1 NAME

JSON::Validator::Schema - Base class for JSON::Validator schemas

=head1 SYNOPSIS

=head2 Basics

  # Create a new schema from a file on disk
  # It is also possible to create the object from JSON::Validator::Schema,
  # but you most likely want to use one of the subclasses.
  my $schema = JSON::Validator::Schema::Draft7->new('file:///cool/beans.yaml');

  # Validate the schema
  die $schema->errors->[0] if $schema->is_invalid;

  # Validate data
  my @errors = $schema->validate({some => 'data'});
  die $errors[0] if @errors;

=head2 Shared store

  my $store = JSON::Validator::Store->new;
  my $schema = JSON::Validator::Schema::Draft7->new(store => $store);

  # Will not fetch the fike from web, if the $store has already retrived
  # the schema
  $schema->resolve('https://api.example.com/cool/beans.json');

=head2 Make a new validation class

  package JSON::Validator::Schema::SomeSchema;
  use Mojo::Base 'JSON::Validator::Schema';
  has specification => 'https://api.example.com/my/spec.json#';
  1;

=head1 DESCRIPTION

L<JSON::Validator::Schema> is the base class for
L<JSON::Validator::Schema::Draft4>,
L<JSON::Validator::Schema::Draft6>,
L<JSON::Validator::Schema::Draft7>,
L<JSON::Validator::Schema::Draft201909>,
L<JSON::Validator::Schema::OpenAPIv2> and
L<JSON::Validator::Schema::OpenAPIv3>.

Any of the classes above can be used instead of L<JSON::Validator> if you know
which draft/version you are working with up front.

=head1 ATTRIBUTES

=head2 errors

  my $array_ref = $schema->errors;

Holds the errors after checking L</data> against L</specification>.
C<$array_ref> containing no elements means L</data> is valid. Each element in
the array-ref is a L<JSON::Validator::Error> object.

This attribute is I<not> changed by L</validate>. It only reflects if the
C<$schema> is valid.

=head2 id

  my $str    = $schema->id;
  my $schema = $schema->id($str);

Holds the ID for this schema. Usually extracted from C<"$id"> or C<"id"> in
L</data>.

=head2 moniker

  $str    = $schema->moniker;
  $schema = $self->moniker("some_name");

Used to get/set the moniker for the given schema. Will be "draft04" if
L</specification> points to a JSON Schema draft URL, and fallback to
empty string if unable to guess a moniker name.

This attribute will (probably) detect more monikers from a given
L</specification> or C</id> in the future.

=head2 specification

  my $str    = $schema->specification;
  my $schema = $schema->specification($str);

The URL to the specification used when checking for L</errors>. Usually
extracted from C<"$schema"> or C<"schema"> in L</data>.

=head2 store

  $store = $jv->store;

Holds a L<JSON::Validator::Store> object that caches the retrieved schemas.
This object can be shared amongst different schema objects to prevent
a schema from having to be downloaded again.

=head1 METHODS

=head2 bundle

  my $bundled = $schema->bundle;

C<$bundled> is a new L<JSON::Validator::Schema> object where none of the "$ref"
will point to external resources. This can be useful, if you want to have a
bunch of files locally, but hand over a single file to a client.

  Mojo::File->new("client.json")
    ->spurt(Mojo::JSON::to_json($schema->bundle->data));

=head2 coerce

  my $schema   = $schema->coerce("booleans,defaults,numbers,strings");
  my $schema   = $schema->coerce({booleans => 1});
  my $hash_ref = $schema->coerce;

Set the given type to coerce. Before enabling coercion this module is very
strict when it comes to validating types. Example: The string C<"1"> is not
the same as the number C<1>. Note that it will also change the internal
data-structure of the validated data: Example:

  $schema->coerce({numbers => 1});
  $schema->data({properties => {age => {type => "integer"}}});

  my $input = {age => "42"};
  $schema->validate($input);
  # $input->{age} is now an integer 42 and not the string "42"

=head2 contains

See L<Mojo::JSON::Pointer/contains>.

=head2 data

  my $hash_ref = $schema->data;
  my $schema   = $schema->data($bool);
  my $schema   = $schema->data($hash_ref);
  my $schema   = $schema->data($url);

Will set a structure representing the schema. In most cases you want to
use L</resolve> instead of L</data>.

=head2 get

  my $data = $schema->get($json_pointer);
  my $data = $schema->get($json_pointer, sub { my ($data, $json_pointer) = @_; });

Called with one argument, this method acts like L<Mojo::JSON::Pointer/get>,
while if called with two arguments it will work like
L<JSON::Validator::Util/schema_extract> instead:

  JSON::Validator::Util::schema_extract($schema->data, sub { ... });

The second argument can be C<undef()>, if you don't care about the callback.

See L<Mojo::JSON::Pointer/get>.

=head2 is_invalid

  my $bool = $schema->is_invalid;

Returns true if the schema in L</data> is invalid. Internally this method calls
L</errors> which will validate L</data> agains L</specification>.

=head2 load_and_validate_schema

This method will be removed in a future release.

=head2 new

  my $schema = JSON::Validator::Schema->new($data);
  my $schema = JSON::Validator::Schema->new($data, %attributes);
  my $schema = JSON::Validator::Schema->new(%attributes);

Construct a new L<JSON::Validator::Schema> object. Passing on C<$data> as the
first argument will cause L</resolve> to be called, meaning the constructor
might throw an exception if the schema could not be successfully resolved.

=head2 resolve

  $schema = $schema->resolve;
  $schema = $schema->resolve($data);

Used to resolve L</data> or C<$data> and store the resolved schema in L</data>.
If C<$data> is an C<$url> on contains "$ref" pointing to an URL, then these
schemas will be downloaded and resolved as well.

=head2 schema

This method will be removed in a future release.

=head2 validate

  my @errors = $schema->validate($any);

Will validate C<$any> against the schema defined in L</data>. Each element in
C<@errors> is a L<JSON::Validator::Error> object.

=head1 SEE ALSO

L<JSON::Validator>.

=cut
