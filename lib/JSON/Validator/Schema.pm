package JSON::Validator::Schema;
use Mojo::Base 'JSON::Validator';    # TODO: Change this to "use Mojo::Base -base"

use Carp qw(carp);
use JSON::Validator::Formats;
use JSON::Validator::URI qw(uri);
use JSON::Validator::Util qw(E data_checksum data_type is_bool is_num is_type json_pointer prefix_errors schema_type);
use List::Util qw(uniq);
use Mojo::JSON qw(false true);
use Mojo::JSON::Pointer;
use Scalar::Util qw(blessed refaddr);

has errors => sub {
  my $self      = shift;
  my $uri       = $self->specification || 'http://json-schema.org/draft-04/schema#';
  my $validator = $self->new(%$self, _refs => {})->data($uri)->resolve;
  return [$self->_validate_id($self->id), $validator->validate($self->resolve->data)];
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

has recursive_data_protection => 1;

has specification => sub {
  my $data = shift->data;
  is_type($data, 'HASH') ? $data->{'$schema'} || $data->{schema} || '' : '';
};

has _refs => sub { +{} };

sub bundle {
  my $self = shift;

  my ($ref_lookup, $clone, @refs, %seen) = ({});
  $clone = sub {
    my $source = shift;
    my $type   = ref $source;

    if ($type eq 'HASH' and $source->{'$ref'} and !ref $source->{'$ref'}) {
      my ($base_url, $fragment) = split '#', $source->{'$ref'};
      $seen{$fragment} = $fragment;
      my $clone = {%$source};
      push @refs, [$clone, $source] if $base_url;
      return $clone;
    }

    return {map { ($_ => $clone->($source->{$_})) } keys %$source} if $type eq 'HASH';
    return [map { $clone->($_) } @$source]                         if $type eq 'ARRAY';
    return $source;
  };

  my $bundle = $clone->($self->data);

  while (my $ref = shift @refs) {
    my $uri = $ref->[0]{'$ref'};
    unless ($seen{$uri}) {
      my @path = $self->_bundle_ref_path($uri, \%seen);
      $seen{$uri} = join '/', '#', @path;

      my ($leaf, $insert_at) = (pop @path, $bundle);
      $insert_at = $insert_at->{shift @path} //= {} while @path;
      my $state = $self->_state({schema => $ref->[1]});
      $insert_at->{$leaf} = $state->{schema};
      $ref_lookup->{refaddr($insert_at->{$leaf})} = $state;
    }

    $ref->[0]{'$ref'} = $seen{$uri};
  }

  return $self->new(%$self, data => $bundle, _refs => $ref_lookup);
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
  my ($self, $pointer, $cb) = @_;
  my %state = (root => $self->data, schema => $self->data, pos => '');
  return $self->_get([@$pointer], \%state, $cb) if is_type $pointer, 'ARRAY';
  return $self->_get([split '/', $pointer], \%state, $cb) if $pointer =~ s!^/!!;
  return length $pointer ? undef : $self->data;
}

sub is_invalid { !!@{shift->errors} }

sub load_and_validate_schema { Carp::confess('load_and_validate_schema(...) is unsupported.') }

sub new {
  my $class = shift;
  return $class->SUPER::new(@_) unless @_ % 2;
  return $class->SUPER::new(data => shift, @_)->resolve;
}

sub resolve {
  my $self = shift;

  my $data = $self->data;
  my $state
    = !ref $data                              ? $self->store->resolve($data)
    : (blessed $data && $data->can('to_abs')) ? $self->store->resolve($data->to_abs->to_string)
    :                                           {root => $data, schema => $data};

  $self->_refs({});
  $self->data($state->{schema});
  $self->id($state->{id} || JSON::Validator::Util::urn($state->{schema})) unless $self->id;
  $state->{id} ||= $self->id;

  my (@topics, @refs, %seen) = ([$state->{schema}, $state]);

  # Search the whole document for id/$id/$ref/$recursiveRef/...
TOPIC:
  while (@topics) {
    my ($schema, $state) = @{shift @topics};

    if (is_type $schema, 'ARRAY') {
      push @topics, map { [$_, $state] } @$schema;
    }
    elsif (is_type $schema, 'HASH') {
      next TOPIC if $seen{refaddr($schema)}++;
      $state = $self->_resolve_object($state, $schema, \@refs, \my %found);
      ref $schema->{$_} and !$found{$_} and push @topics, [$schema->{$_}, $state] for keys %$schema;
    }
  }

  # Need to resolve the $ref/$recursiveRef/... after id/$id/$anchor/... is found above
  @topics = ();
  while (my $r = shift @refs) {
    my ($schema, $state) = @$r;
    my $resolved = $self->store->resolve($self->_normalize_ref($schema), $state);
    $self->_refs->{refaddr($schema)} = $resolved;
    push @topics, [$resolved->{schema}, $resolved];
  }

  # Traverse the newly discovered sub documents, if any
  goto TOPIC if @topics;

  return $self;
}

sub validate {
  my ($self, $data, $schema) = @_;
  my %state  = (base_url => $self->id, path => '', root => $self->data, schema => $schema // $self->data, seen => {});
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

sub _bundle_ref_path { ('definitions', shift->_flat_ref_name(@_)) }

sub _flat_ref_name {
  my ($self, $ref, $seen) = @_;
  my $uri = uri $ref;

  my $l = 0;
  while (1) {
    my $flat = join '-', map { s!^\W+!!; s!\W!_!g; $_ } grep { defined $_ } pop @{$uri->path}, $uri->fragment,
      $l++ ? substr data_checksum($ref), 0, $l : undef;
    return $flat if !$seen->{$flat} or $l >= 32;
  }
}

sub _get {
  my ($self, $pointer, $state, $cb) = @_;
  my $schema;

  $state  = $self->_state_for_get($state->{schema}, $state) if $pointer->[0] and $pointer->[0] ne '$ref';
  $schema = $state->{schema};
  while (@$pointer) {
    my $p = shift @$pointer;

    unless (defined $p) {
      my $i = 0;
      return Mojo::Collection->new(
        map { $self->_get([@$pointer], {%$state, schema => $_->[0], pos => json_pointer($state->{pos}, $_->[1])}, $cb) }
          ref $schema eq 'ARRAY' ? (map { [$_, $i++] } @$schema)
        : ref $schema eq 'HASH' ? (map { [$schema->{$_}, $_] } sort keys %$schema)
        :                         ([$schema, ''])
      );
    }

    $p =~ s!~1!/!g;
    $p =~ s/~0/~/g;
    $state->{pos} = json_pointer $state->{pos}, $p;

    if (ref $schema eq 'HASH' and exists $schema->{$p}) {
      $schema = $schema->{$p};
    }
    elsif (ref $schema eq 'ARRAY' and $p =~ /^\d+$/ and @$schema > $p) {
      $schema = $schema->[$p];
    }
    else {
      return undef;
    }

    if ($pointer->[0] and $pointer->[0] ne '$ref') {
      $state  = $self->_state_for_get($schema, $state);
      $schema = $state->{schema};
    }
  }

  return $cb->($schema, $state->{pos}) if $cb;
  return $schema;
}

sub _normalize_ref { $_[1]->{'$ref'} }

sub _resolve_object {
  my ($self, $state, $schema, $refs, $found) = @_;

  if ($schema->{id} and !ref $schema->{id}) {
    my $id = uri $schema->{id}, $state->{base_url};
    $self->store->add($id => $schema);
    $state = {%$state, base_url => $id->fragment(undef)->to_string};
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
  while (ref $schema eq 'HASH' and $schema->{'$ref'} and !ref $schema->{'$ref'}) {
    my $addr = refaddr $schema;
    last if $seen{$addr}++;
    $schema = $self->_refs->{$addr}->{schema}
      // Carp::confess(qq(You have to call resolve() before validate() to lookup "$schema->{'$ref'}".));
  }

  return {%$curr, %override, schema => $schema};
}

sub _state_for_get {
  my ($self, $schema, $state) = @_;
  return $self->_refs->{refaddr($schema)} if ref $schema eq 'HASH' and $schema->{'$ref'} and !ref $schema->{'$ref'};
  return {%$state, schema => $schema};
}

sub _validate {
  my ($self, $data, $state) = @_;
  my $schema = $state->{schema};
  return $schema ? () : E $state->{path}, [not => 'not'] if is_bool $schema;

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

sub _validate_id {
  my ($self, $id) = @_;
  return unless length $id;
  return E '/id', 'Fragment not allowed.' if $id =~ /\#./;
  return E '/id', 'Relative URL not allowed.' unless $id =~ /^\w+:/ or -e $id or $id =~ m!^/!;
  return;
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
  if (is_bool $cmp_with) {
    push @errors, E $path, [$expected => ex_maximum => $value, $schema->{maximum}] unless $value < $schema->{maximum};
  }
  elsif (is_num $cmp_with) {
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
  if (is_bool $cmp_with) {
    push @errors, E $path, [$expected => ex_minimum => $value, $schema->{minimum}] unless $value > $schema->{minimum};
  }
  elsif (is_num $cmp_with) {
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

  return if is_bool $_[1];
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
  unless (is_num $value) {
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
  my @dkeys = keys %$data;
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
    push @{$rules{$_}}, $r for grep { $_ =~ /$p/ } @dkeys;
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

  for my $k (uniq @{$schema->{required} || []}) {
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

  for my $k (keys %rules) {
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
  $schema->data('https://api.example.com/cool/beans.json')->resolve;

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
  my $schema   = $schema->data($uri);

Will set a structure representing the schema. In most cases you want to
use L</resolve> instead of L</data>.

=head2 get

  my $data = $schema->get([@json_pointer]);
  my $data = $schema->get($json_pointer);
  my $data = $schema->get($json_pointer, sub { my ($data, $json_pointer) = @_; });

This method will extract data from L</data>, using a C<$json_pointer> -
L<RFC 6901|http://tools.ietf.org/html/rfc6901>. It can however be used in a more
complex way by passing in an array-ref: The array-ref can contain C<undef()>
values, will result in extracting any element on that point, regardsless of
value. In that case a L<Mojo::Collection> will be returned.

A callback can also be given. This callback will be called each time the
C<$json_pointer> matches some data, and will pass in the C<$json_pointer> at
that place.

In addition if this method "sees" a JSON-Schema C<$ref> on the way, the "$ref"
will be followed into any given sub schema.

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

Used to resolve L</data> and store the resolved schema in L</data>.  If
C<$data> is an C<$uri> or contains "$ref", then these schemas will be
downloaded and resolved as well.

If L</data> does not contain an "id" or "$id", then L</id> will be assigned a
autogenerated "urn". This "urn" might be changed in future releases, but should
always be the same for the same L</data>.

=head2 schema

This method will be removed in a future release.

=head2 validate

  my @errors = $schema->validate($any);

Will validate C<$any> against the schema defined in L</data>. Each element in
C<@errors> is a L<JSON::Validator::Error> object.

=head1 SEE ALSO

L<JSON::Validator>.

=cut
